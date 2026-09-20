# MDT Client

MDT (My Dev Tools) is a Phoenix LiveView app packaged with Tauri and ElixirKit.

## Screens

The app boots to a login screen (`/`), which leads to the tool picker (`/tools`)
and from there into a tool:

* **HTTP Client** (`/tools/http`) — searchable request history grouped by day,
  tabbed requests, params/headers/auth/body editors, a response viewer, and
  curl import/export. `Ctrl+Enter` sends; the history and the request/response
  split are drag resizable.
* **Git GUI** (`/tools/git`) — not built yet.

The interface is front end only for now: authentication always succeeds and the
HTTP client answers with canned responses from `MDTClient.HttpClient`, so there
is no networking or persistence behind it yet.

Both themes live in `assets/css/app.css` as one set of tokens: the dark values
follow the "Oliveigah Dark" Zed theme and the light ones override them under
`:root[data-theme="light"]`. The title bar toggle switches between dark, light
and the system preference, and the script in `root.html.heex` applies the
choice (along with the panel sizes dragged in the HTTP client) before the first
paint.

The desktop app has no browser chrome, so `assets/js/zoom.js` implements the
usual zoom controls — `Ctrl`/`Cmd` with `+`, `-`, `0`, or the mouse wheel —
scaling the interface through the same CSS variable mechanism. In a browser the
handlers stay out of the way and the browser's own zoom applies; set
`mdt:force-zoom` in local storage to exercise the app's zoom there.

To build the AppImage:

```bash
./scripts/build-linux.sh
```

For a quick build using an already configured local Elixir/Rust/Tauri toolchain:

```bash
MIX_ENV=prod mix deps.get --only prod --check-locked
MIX_ENV=prod mix assets.setup
NO_STRIP=1 APPIMAGE_EXTRACT_AND_RUN=1 cargo tauri build --bundles appimage
```

This local build writes to `src-tauri/target/release/bundle/appimage/` and inherits
the host's library requirements.

## Development

```bash
mix setup
cargo tauri dev
```
