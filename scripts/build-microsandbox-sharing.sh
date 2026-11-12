#!/usr/bin/env bash
# Build the pinned runtime patch on the machine that will run it.
set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
  echo "This build helper targets Linux hosts." >&2
  exit 1
fi

PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SOURCE=${MDT_MSB_SOURCE:-$PROJECT/tmp/microsandbox-live-sharing}
PATCH=$PROJECT/priv/sandbox/microsandbox-live-sharing.patch
REVISION=60fc5071b34e6cc2671c84c8dc07709795d45d27
OUTPUT=$PROJECT/tmp/microsandbox-sharing-runtime

for tool in git cargo rustc curl; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done

if [[ ! -d "$SOURCE" ]]; then
  mkdir -p -- "$(dirname -- "$SOURCE")"
  git clone --depth 1 --branch v0.7.14 \
    https://github.com/superradcompany/microsandbox.git "$SOURCE"
fi
if [[ $(git -C "$SOURCE" rev-parse HEAD) != "$REVISION" ]]; then
  echo "Expected Microsandbox v0.7.14 at $REVISION; refusing to patch another revision." >&2
  exit 1
fi

if git -C "$SOURCE" apply --check "$PATCH" 2>/dev/null; then
  git -C "$SOURCE" apply "$PATCH"
elif ! git -C "$SOURCE" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "The sharing patch cannot be applied cleanly. Existing source changes were preserved." >&2
  exit 1
fi

export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$PROJECT/tmp/microsandbox-sharing-target}
export CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-2}
export CARGO_PROFILE_DEV_DEBUG=0
export CARGO_INCREMENTAL=0

# Supply the matching guest agent explicitly. Disable build-time runtime
# installation so building never writes to the host's live MSB_HOME.
export MSB_EMBED_ARTIFACTS_DIR=${MSB_EMBED_ARTIFACTS_DIR:-$PROJECT/tmp/microsandbox-sharing-artifacts}
mkdir -p -- "$MSB_EMBED_ARTIFACTS_DIR"
if [[ ! -f "$MSB_EMBED_ARTIFACTS_DIR/agentd" ]]; then
  ARCHITECTURE=$(uname -m)
  case "$ARCHITECTURE" in x86_64|aarch64) ;; *) echo "Unsupported architecture: $ARCHITECTURE" >&2; exit 1 ;; esac
  AGENT_TEMPORARY=$(mktemp "$MSB_EMBED_ARTIFACTS_DIR/.agentd.XXXXXX")
  trap 'rm -f -- "$AGENT_TEMPORARY"' EXIT
  curl --fail --location --silent --show-error --proto '=https' \
    "https://github.com/superradcompany/microsandbox/releases/download/v0.7.14/agentd-$ARCHITECTURE" \
    --output "$AGENT_TEMPORARY"
  mv -f -- "$AGENT_TEMPORARY" "$MSB_EMBED_ARTIFACTS_DIR/agentd"
  trap - EXIT
fi

cd -- "$SOURCE"
cargo test --locked --no-default-features --features embed-binaries -p microsandbox-filesystem --lib
# Keep release optimizations while avoiding the memory cost of whole-program LTO.
CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
  cargo build --locked --release --no-default-features \
  --features embed-binaries,net,ssh,keyring -p microsandbox-cli

mkdir -p -- "$OUTPUT"
TEMPORARY=$(mktemp "$OUTPUT/.msb.XXXXXX")
trap 'rm -f -- "$TEMPORARY"' EXIT
install -m 755 -- "$CARGO_TARGET_DIR/release/msb" "$TEMPORARY"
"$TEMPORARY" --version
mv -f -- "$TEMPORARY" "$OUTPUT/msb"
printf 'release\n' > "$OUTPUT/build-profile"
sha256sum -- "$OUTPUT/msb" "$PATCH" > "$OUTPUT/checksums.sha256"
echo "Built patched runtime: $OUTPUT/msb"
