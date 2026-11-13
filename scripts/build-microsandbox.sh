#!/usr/bin/env bash
# Builds the microsandbox runtime MDT ships with: msb from a pinned commit of
# MDT's fork (oliveigah/microsandbox: an upstream release plus the ESTALE fix
# for host-replaced files), and that release's libkrunfw. Everything is pinned
# here, so every MDT build carries the same runtime.
#
# Output (default priv/microsandbox, which the release copies along):
#   bin/msb                 the CLI, guest agent embedded
#   lib/libkrunfw.so.5.6.1  the guest kernel; msb finds it beside bin/
#
# Needs git, curl, sha256sum, a C compiler and Rust/Cargo (strace too, for two
# of the filesystem tests). Downloads go through checksums; the source must be
# the pinned commit, with no local changes.
set -Eeuo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/build-microsandbox.sh [OUTPUT_DIR]\n'
  printf "Build msb from MDT's pinned fork commit, and libkrunfw. Default output: priv/microsandbox\n"
  printf 'Env: MDT_MSB_SOURCE, MDT_MSB_DOWNLOADS, CARGO_TARGET_DIR, MDT_MSB_SKIP_TESTS=1\n'
  exit 0
fi
[[ $# -le 1 ]] || { printf 'At most one argument. Use --help for usage.\n' >&2; exit 1; }
[[ $(uname -s) == Linux ]] || { printf 'This build targets Linux.\n' >&2; exit 1; }

# The fork commit: v0.7.15 (plus one CI-only upstream commit) and
# "fix: ESTALE for host replaced files".
REPOSITORY=https://github.com/oliveigah/microsandbox.git
REVISION=6626e7cb280069f522c03a815c760ace8931b370
# The upstream release it is based on: its guest agent and libkrunfw, and what
# `msb --version` prints.
UPSTREAM=0.7.15
# This runtime's identity, written to VERSION: a build whose VERSION differs
# is stale.
VERSION=$UPSTREAM+${REVISION:0:9}
LIBKRUNFW=libkrunfw.so.5.6.1
# From the v0.7.15 release's asset digests.
case $(uname -m) in
  x86_64)
    ARCH=x86_64
    AGENTD_SHA256=c9b9cc8bf660ed49db0ce5732adc74fadd53ceb4a3f16a1575101610f8e2a1fd
    LIBKRUNFW_SHA256=e54cd5d8849162bbdb136d3342f0601be1b713a2af529bd60d335ec2d44fdb7c
    ;;
  aarch64)
    ARCH=aarch64
    AGENTD_SHA256=04fe96ce2103d17ba88e22c3c90642a1071f5e75bec16525e84c9d53fb5c1008
    LIBKRUNFW_SHA256=eb59d55be54791221c58201e333c21a4f39086b374a1eeea01517f85fdae171c
    ;;
  *) printf 'Unsupported architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac
RELEASE=https://github.com/superradcompany/microsandbox/releases/download/v$UPSTREAM

project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=${1:-$project/priv/microsandbox}
# MDT_MSB_SOURCE may name an existing checkout (your clone of the fork); it
# must be at REVISION with no local changes, and is never modified.
source=${MDT_MSB_SOURCE:-$project/tmp/microsandbox-src/$REVISION}
downloads=${MDT_MSB_DOWNLOADS:-$project/tmp/microsandbox-downloads}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-$project/tmp/microsandbox-target}

for tool in git curl sha256sum cc cargo; do
  command -v "$tool" >/dev/null || { printf 'Missing build tool: %s\n' "$tool" >&2; exit 1; }
done

# fetch NAME SHA256: the release asset NAME in $downloads, checked.
fetch() {
  local name=$1 sha256=$2 file=$downloads/$UPSTREAM/$1
  if [[ ! -f "$file" ]] || ! printf '%s  %s\n' "$sha256" "$file" | sha256sum --check --status; then
    mkdir -p -- "$(dirname -- "$file")"
    curl --fail --location --silent --show-error --proto '=https' \
      --retry 5 --retry-delay 2 --output "$file.part" "$RELEASE/$name"
    printf '%s  %s\n' "$sha256" "$file.part" | sha256sum --check --strict --quiet
    mv -f -- "$file.part" "$file"
  fi
  printf '%s\n' "$file"
}

printf '==> microsandbox %s source (%s)\n' "$VERSION" "$REPOSITORY"
if [[ ! -d "$source" ]]; then
  # Only this one commit, fetched by hash; GitHub serves any pushed commit.
  partial=$source.partial
  rm -rf -- "$partial"
  mkdir -p -- "$partial"
  git -C "$partial" init --quiet
  git -C "$partial" fetch --quiet --depth 1 "$REPOSITORY" "$REVISION"
  git -C "$partial" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
  mv -- "$partial" "$source"
fi
if [[ $(git -C "$source" rev-parse HEAD) != "$REVISION" ]]; then
  printf 'Expected %s at %s; refusing to build another commit.\n' "$source" "$REVISION" >&2
  exit 1
fi
if [[ -n $(git -C "$source" status --porcelain --untracked-files=no) ]]; then
  printf '%s has local changes; refusing to build anything but %s.\n' "$source" "$REVISION" >&2
  exit 1
fi

printf '==> release artifacts\n'
agentd=$(fetch "agentd-$ARCH" "$AGENTD_SHA256")
libkrunfw=$(fetch "libkrunfw-linux-$ARCH.so" "$LIBKRUNFW_SHA256")

# The guest agent is embedded from here; building never downloads or
# installs anything into a microsandbox home.
export MSB_EMBED_ARTIFACTS_DIR=$downloads/$UPSTREAM/embed
mkdir -p -- "$MSB_EMBED_ARTIFACTS_DIR"
install -m 755 -- "$agentd" "$MSB_EMBED_ARTIFACTS_DIR/agentd"
export CARGO_INCREMENTAL=0

cd -- "$source"
if [[ ${MDT_MSB_SKIP_TESTS:-} != 1 ]]; then
  printf '==> filesystem tests (the crate with the fix)\n'
  # Two close-error tests trace the process with strace; without it they
  # fail on setup, so they are skipped rather than failing the build.
  skip=()
  if ! command -v strace >/dev/null; then
    printf 'strace not found: skipping the two close-error tests that need it\n'
    skip=(--skip test_create_write_close_budget --skip test_flush_reports_backing_close_errors_by_default)
  fi
  cargo test --locked --no-default-features --features embed-binaries -p microsandbox-filesystem --lib -- "${skip[@]}"
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
[[ "$reported" == "msb $UPSTREAM" ]] || { printf 'Built msb reports %q\n' "$reported" >&2; exit 1; }
rm -rf -- "$staged/home"
printf '%s\n' "$VERSION" > "$staged/VERSION"

rm -rf -- "$output"
mv -- "$staged" "$output"
trap - EXIT
printf '==> ready: %s (%s)\n' "$output" "$reported"
