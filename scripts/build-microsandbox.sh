#!/usr/bin/env bash
# Builds the microsandbox runtime MDT ships with: msb at a pinned release with
# MDT's live-sharing patch, and that release's libkrunfw. Both are pinned
# here, so every MDT build carries the same runtime.
#
# Output (default priv/microsandbox, which the release copies along):
#   bin/msb                 the CLI, guest agent embedded
#   lib/libkrunfw.so.5.6.1  the guest kernel; msb finds it beside bin/
#
# Needs git, curl, sha256sum, a C compiler and Rust/Cargo. Downloads go
# through checksums; the source must be the pinned revision.
set -Eeuo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/build-microsandbox.sh [OUTPUT_DIR]\n'
  printf 'Build the pinned, patched msb and libkrunfw. Default output: priv/microsandbox\n'
  printf 'Env: MDT_MSB_SOURCE, MDT_MSB_DOWNLOADS, CARGO_TARGET_DIR, MDT_MSB_SKIP_TESTS=1\n'
  exit 0
fi
[[ $# -le 1 ]] || { printf 'At most one argument. Use --help for usage.\n' >&2; exit 1; }
[[ $(uname -s) == Linux ]] || { printf 'This build targets Linux.\n' >&2; exit 1; }

VERSION=0.7.14
REVISION=60fc5071b34e6cc2671c84c8dc07709795d45d27
LIBKRUNFW=libkrunfw.so.5.6.1
# From the v0.7.14 release's asset digests.
case $(uname -m) in
  x86_64)
    ARCH=x86_64
    AGENTD_SHA256=743ba6497d7006838e1276bc4965b524ca6718a638d613e9cfc8240c8f5f5276
    LIBKRUNFW_SHA256=e5480f2feb911c5d9a508559cc13e35983c9811acc2f136e24bb8040461a7a52
    ;;
  aarch64)
    ARCH=aarch64
    AGENTD_SHA256=6eb84756979eb1310b7dd54c5684b108ff7a4c0de643337a8462729b04cb770d
    LIBKRUNFW_SHA256=aa1234f0f4c94cb3d2d68bfdc08fbab6602c8635ae1d5fcab9e0f16b8ff3276b
    ;;
  *) printf 'Unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
RELEASE=https://github.com/superradcompany/microsandbox/releases/download/v$VERSION

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
patch=$project/priv/sandbox/microsandbox-live-sharing.patch
output=${1:-$project/priv/microsandbox}
source=${MDT_MSB_SOURCE:-$project/tmp/microsandbox-live-sharing}
downloads=${MDT_MSB_DOWNLOADS:-$project/tmp/microsandbox-downloads}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$project/tmp/microsandbox-target}

for tool in git curl sha256sum cc cargo; do
  command -v "$tool" >/dev/null || { printf 'Missing build tool: %s\n' "$tool" >&2; exit 1; }
done

# fetch NAME SHA256: the release asset NAME in $downloads, checked.
fetch() {
  local name=$1 sha256=$2 file=$downloads/$VERSION/$1
  if [[ ! -f "$file" ]] || ! printf '%s  %s\n' "$sha256" "$file" | sha256sum --check --status; then
    mkdir -p -- "$(dirname -- "$file")"
    curl --fail --location --silent --show-error --proto '=https' \
      --retry 5 --retry-delay 2 --output "$file.part" "$RELEASE/$name"
    printf '%s  %s\n' "$sha256" "$file.part" | sha256sum --check --strict --quiet
    mv -f -- "$file.part" "$file"
  fi
  printf '%s\n' "$file"
}

printf '==> microsandbox v%s source\n' "$VERSION"
if [[ ! -d "$source" ]]; then
  mkdir -p -- "$(dirname -- "$source")"
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "v$VERSION" \
    https://github.com/superradcompany/microsandbox.git "$source"
fi
if [[ $(git -C "$source" rev-parse HEAD) != "$REVISION" ]]; then
  printf 'Expected v%s at %s in %s; refusing to patch another revision.\n' \
    "$VERSION" "$REVISION" "$source" >&2
  exit 1
fi
if git -C "$source" apply --check "$patch" 2>/dev/null; then
  git -C "$source" apply "$patch"
elif ! git -C "$source" apply --reverse --check "$patch" 2>/dev/null; then
  printf 'The live-sharing patch does not apply to %s; other changes there were kept.\n' "$source" >&2
  exit 1
fi

printf '==> release artifacts\n'
agentd=$(fetch "agentd-$ARCH" "$AGENTD_SHA256")
libkrunfw=$(fetch "libkrunfw-linux-$ARCH.so" "$LIBKRUNFW_SHA256")

# The guest agent is embedded from here; building never downloads or
# installs anything into a microsandbox home.
export MSB_EMBED_ARTIFACTS_DIR=$downloads/$VERSION/embed
mkdir -p -- "$MSB_EMBED_ARTIFACTS_DIR"
install -m 755 -- "$agentd" "$MSB_EMBED_ARTIFACTS_DIR/agentd"
export CARGO_INCREMENTAL=0

cd -- "$source"
if [[ ${MDT_MSB_SKIP_TESTS:-} != 1 ]]; then
  printf '==> filesystem tests (the patched crate)\n'
  cargo test --locked --no-default-features --features embed-binaries -p microsandbox-filesystem --lib
fi

printf '==> building msb\n'
# Release optimizations without whole-program LTO, which costs a lot of memory.
CARGO_PROFILE_RELEASE_LTO=false CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 \
  cargo build --locked --release --no-default-features \
  --features embed-binaries,net,ssh,keyring -p microsandbox-cli

mkdir -p -- "$(dirname -- "$output")"
staged=$(mktemp -d "$(dirname -- "$output")/.microsandbox.XXXXXX")
trap 'rm -rf -- "$staged"' EXIT
# mktemp makes it 0700; packaged under a root-owned folder, users must read it.
chmod 755 -- "$staged"
install -D -m 755 -- "$CARGO_TARGET_DIR/release/msb" "$staged/bin/msb"
install -D -m 644 -- "$libkrunfw" "$staged/lib/$LIBKRUNFW"
reported=$(MSB_HOME="$staged/home" "$staged/bin/msb" --version)
[[ "$reported" == "msb $VERSION" ]] || { printf 'Built msb reports %q\n' "$reported" >&2; exit 1; }
rm -rf -- "$staged/home"
printf '%s\n' "$VERSION" > "$staged/VERSION"

rm -rf -- "$output"
mv -- "$staged" "$output"
trap - EXIT
printf '==> ready: %s (%s)\n' "$output" "$reported"
