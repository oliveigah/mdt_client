use tauri::Manager;

const DESKTOP_PORT: &str = "12995";

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0").expect("failed to listen");

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(move |app| {
            let app_handle = app.handle().clone();

            pubsub.subscribe("messages", move |msg| {
                if msg == b"ready" {
                    create_window(&app_handle);
                } else {
                    println!("[rust] {}", String::from_utf8_lossy(msg));
                }
            });

            let app_handle = app.handle().clone();

            tauri::async_runtime::spawn_blocking(move || {
                let mut command = elixir_command(&app_handle);
                command.env("ELIXIRKIT_PUBSUB", pubsub.url());
                let status = command.status().expect("failed to start Elixir");

                app_handle.exit(status.code().unwrap_or(1));
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

fn create_window(app_handle: &tauri::AppHandle) {
    let n = app_handle.webview_windows().len() + 1;
    let port = if cfg!(debug_assertions) {
        "4000"
    } else {
        DESKTOP_PORT
    };
    let url = tauri::WebviewUrl::External(format!("http://127.0.0.1:{port}").parse().unwrap());
    tauri::WebviewWindowBuilder::new(app_handle, format!("window-{}", n), url)
        .title("MDT")
        .inner_size(800.0, 600.0)
        .build()
        .unwrap();
}

fn elixir_command(app_handle: &tauri::AppHandle) -> std::process::Command {
    if cfg!(debug_assertions) {
        let mut command = elixirkit::mix("phx.server", &[]);
        command.current_dir("..");
        command
    } else {
        let rel_dir = app_handle.path().resource_dir().unwrap().join("rel");
        let release_tmp = app_handle.path().app_cache_dir().unwrap().join("release");
        std::fs::create_dir_all(&release_tmp).expect("failed to create Elixir runtime directory");

        let mut command = elixirkit::release(rel_dir, "mdt_client");
        // Installed resources live under /usr/lib and are not writable by the user.
        command.env("RELEASE_TMP", release_tmp);
        command.env("PHX_SERVER", "true");
        command.env("PHX_HOST", "127.0.0.1");
        command.env("PORT", DESKTOP_PORT);
        command.env(
            "SECRET_KEY_BASE",
            "fFVYOHjB1Go6gFlKCrVNtCRXvJeFbfs9EPLqc1kWNe2PV4aC/apcSxrX7hafE0MN",
        );
        command
    }
}
