use std::process::Child;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::Manager;

const DESKTOP_PORT: &str = "12995";

struct DesktopProcess {
    child: Mutex<Option<Child>>,
    restarting: AtomicBool,
}

#[tauri::command]
fn set_webview_zoom(webview: tauri::WebviewWindow, scale: f64) -> Result<(), String> {
    if !scale.is_finite() || !(0.5..=3.0).contains(&scale) {
        return Err("zoom must be between 0.5 and 3.0".into());
    }

    webview.set_zoom(scale).map_err(|error| error.to_string())
}

#[tauri::command]
fn restart_app(app: tauri::AppHandle, process: tauri::State<'_, Arc<DesktopProcess>>) {
    process.restarting.store(true, Ordering::SeqCst);

    if let Some(mut child) = process.child.lock().unwrap().take() {
        let _ = child.kill();
        let _ = child.wait();
    }

    app.restart();
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let pubsub = elixirkit::PubSub::listen("tcp://127.0.0.1:0").expect("failed to listen");

    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![set_webview_zoom, restart_app])
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(move |app| {
            let app_handle = app.handle().clone();
            let process = Arc::new(DesktopProcess {
                child: Mutex::new(None),
                restarting: AtomicBool::new(false),
            });
            app.manage(process.clone());

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
                let child = command.spawn().expect("failed to start Elixir");
                *process.child.lock().unwrap() = Some(child);

                loop {
                    let status = {
                        let mut guard = process.child.lock().unwrap();
                        guard
                            .as_mut()
                            .and_then(|child| child.try_wait().ok().flatten())
                    };

                    if let Some(status) = status {
                        if !process.restarting.load(Ordering::SeqCst) {
                            app_handle.exit(status.code().unwrap_or(1));
                        }
                        break;
                    }

                    if process.restarting.load(Ordering::SeqCst) {
                        break;
                    }

                    std::thread::sleep(Duration::from_millis(100));
                }
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
        .decorations(false)
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
        command.env("MDT_DESKTOP_BUILD", "true");
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
