#!/usr/bin/env bash
# Builds MDT's relay (native/mdt_relay), the first process in the bubble the
# VM runs in, into the runtime folder, beside msb:
#
#   bin/mdt-relay
#
# It has no dependencies, so the build needs Rust/Cargo and no network. It
# links only glibc, like msb, so the package build runs it once, on the older
# glibc of the two package targets.
set -Eeuo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/build-relay.sh [OUTPUT_DIR]\n'
  printf 'Build mdt-relay into OUTPUT_DIR/bin. Default output: priv/microsandbox\n'
  exit 0
fi
[[ $# -le 1 ]] || { printf 'At most one argument. Use --help for usage.\n' >&2; exit 1; }
[[ $(uname -s) == Linux ]] || { printf 'This build targets Linux.\n' >&2; exit 1; }

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=${1:-$root/priv/microsandbox}

cargo build --release --locked --offline --manifest-path "$root/native/mdt_relay/Cargo.toml"
install -D -m 0755 "$root/native/mdt_relay/target/release/mdt-relay" "$out/bin/mdt-relay"
printf 'Built %s\n' "$out/bin/mdt-relay"
