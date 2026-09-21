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
* **Git GUI** (`/tools/git`) — not built yet.

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
choice (along with the panel sizes dragged in the HTTP client) before the first
paint.

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
28.3 and Elixir 1.19.4, and its Rust code is optimized for the build machine's
CPU. Build that package on the Fedora computer where it will run. Docker keeps
separate build caches for both packages.

## Development

```bash
mix setup
cargo tauri dev
```
