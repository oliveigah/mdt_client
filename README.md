# MDT Client

MDT (My Dev Tools) is a Phoenix LiveView app packaged as a native Linux desktop
application with Tauri and ElixirKit.

## Screens

The app boots to a sign in screen (`/`), which leads to the tool picker
(`/tools`) and from there into a tool:

* **HTTP Client** (`/tools/http`) — searchable request history grouped by day,
  tabbed requests, params/headers/auth/body editors, a response viewer, and
  curl import/export. `Ctrl+Enter` sends; the history and the request/response
  split are drag resizable.
* **Git GUI** (`/tools/git`) — a repository tab per folder, over three resizable
  panels: branches and stashes on the left, a lane-drawn commit graph in the
  middle, and an inspector on the right that switches between commit metadata
  and the working tree. The graph is where work happens: right click any commit
  (or use its row menu, or the inspector's Actions button) for checkout, branch
  creation, cherry-pick, revert, merge, rebase, message edits and resets. Refs
  sit in their own column beside the graph, a monitor marking a local branch, a
  cloud a remote one and a tick the branch HEAD is on, and uncommitted work
  takes a dashed WIP row above the newest commit. The working tree keeps
  unstaged and staged files in their own lists, stages, unstages and stashes the
  paths you select, and opens any file's diff over the graph. Folders are chosen
  with the native desktop picker or cloned from a remote, they come back in
  their tabs the next time you open the tool, and the active one refreshes on a
  timer so work done elsewhere shows up. `docs/git-backend.md` covers the
  backend it drives.

Signing in takes a username and a password. The password is stretched into an
encryption key, and everything that identity persists — today the HTTP client's
request history — is written to `~/.mdt_client/identities/<hash>/` encrypted
with it. An unknown username creates a profile; two identities cannot read each
other's data even when they share a password, and there is no way to recover a
forgotten one. `docs/vault.md` covers the design and its limits.

The HTTP client executes requests through Req and persists request history
between app restarts, encrypted at rest.

Both themes live in `assets/css/app.css` as one set of tokens: the dark values
follow the "Oliveigah Dark" Zed theme and the light ones override them under
`:root[data-theme="light"]`. The title bar toggle switches between dark, light
and the system preference, and the script in `root.html.heex` applies the
choice (along with the panel sizes dragged in either tool) before the first
paint.

The interface is served by the embedded Phoenix server, so the webview's origin
is `http://127.0.0.1:<port>` rather than the `tauri://` scheme. Tauri treats
that as a *remote* origin and rejects every IPC call coming from it unless a
capability names the origin explicitly, which is what
`src-tauri/capabilities/local-server.json` does. Anything that calls into Rust
has to be granted there: the folder picker through the dialog plugin, and
`set_webview_zoom` through the app permission in `src-tauri/permissions/`.
Without the grant the call is rejected, which is quiet — the zoom shortcuts, for
instance, silently fall back to scaling the page with CSS. The Rust side has to
be rebuilt for a new plugin, permission or capability to take effect.

The desktop app has no browser chrome, so `assets/js/zoom.js` implements the
usual zoom controls — `Ctrl`/`Cmd` with `+`, `-`, `0`, or the mouse wheel —
scaling the interface through the same CSS variable mechanism. In a browser the
handlers stay out of the way and the browser's own zoom applies; set
`mdt:force-zoom` in local storage to exercise the app's zoom there.

## Linux packages

Docker and the Docker Compose plugin are the only host requirements. Build both
native Linux packages with:

```bash
./scripts/build-linux.sh
```

Or build one package at a time:

```bash
./scripts/build-deb.sh
./scripts/build-rpm.sh
```

All scripts write the finished packages to `dist/`. The default target is
`linux/amd64`, including when the build runs through emulation on an ARM host.
To build ARM64 packages instead, set the platform explicitly:

```bash
PACKAGE_PLATFORM=linux/arm64 ./scripts/build-linux.sh
```

Install a package using the distribution's package manager so its WebKitGTK and
GTK runtime dependencies are installed and kept current by the operating system:

```bash
sudo apt install ./dist/*.deb
# or
sudo dnf install ./dist/*.rpm
```

The Debian package is compiled on Ubuntu 22.04 and the RPM is compiled on Fedora
44. The Phoenix release contains Erlang native libraries, so building each
package on its target distribution family keeps those libraries compatible with
the system OpenSSL ABI. The RPM matches the development toolchain with Erlang
28.3 and Elixir 1.19.4, and its Rust code targets the Fedora computer's AMD Zen 5
CPU even when another computer performs the build. Docker keeps separate build
caches for both packages.

Every push runs the `CI` GitHub Actions workflow. It executes `mix precommit`,
including compilation with warnings treated as errors and the full test suite.

Publishing a GitHub Release runs the `Release Linux packages` workflow. It
checks out the release tag, builds the Debian and Fedora packages independently,
and attaches the `.deb`, `.rpm`, and `SHA256SUMS` files directly to that release.

## Development

```bash
mix setup
cargo tauri dev
```
