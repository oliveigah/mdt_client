# MDT (My Dev Tools)

MDT is a Linux desktop toolbox for the small developer tasks I use every day. I
am rebuilding familiar tools around a local-first workflow: keep past work easy
to find, keep saved data on my machine, and make backups simple without a hosted
account.

## Tools

- **HTTP Client:** Send requests, inspect responses, import or export curl
  commands, and search saved request history.
- **Git GUI:** Browse commits and diffs, manage branches and stashes, and work
  with the staging area across multiple repositories.
- **Diagrams:** Sketch boxes, ellipses, diamonds and arrows, and write on any of
  them or anywhere on the canvas. Tables of typed rows can be related row to
  row, for data models. Every diagram is kept, and search finds a word wherever
  it was written.
- **Backup and restore:** Export a local identity's saved data to one encrypted
  `.mdtexport` file, then import it on another installation.

## Architecture

- **Desktop shell:** Tauri starts a bundled Elixir release through ElixirKit and
  opens its Phoenix server on the local loopback address. It also provides
  native file pickers.
- **Interface:** Phoenix LiveView renders the tools and handles interaction;
  Tailwind CSS and JavaScript provide the desktop UI.
- **Tool logic:** Elixir modules execute HTTP requests with Req and Git
  operations through the installed Git executable.
- **Local data:** HTTP history and diagrams are encrypted under a
  password-protected local identity in `~/.mdt_client/`. Git repositories
  remain in their own folders. The transfer system packages identity data for
  encrypted export and import.

## Development

With Elixir, Erlang, Rust, and the Tauri Linux prerequisites installed:

```bash
mix setup
cargo tauri dev
```

## Linux packages

With Docker and Docker Compose, build Debian and RPM packages into `dist/`:

```bash
./scripts/build-linux.sh
```

The default target is `linux/amd64`. Set `PACKAGE_PLATFORM=linux/arm64` to build
ARM64 packages.
