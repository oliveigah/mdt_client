# MDT Client

MDT (My Dev Tools) is a Phoenix LiveView app packaged with Tauri and ElixirKit.

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
