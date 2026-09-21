#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/build-linux.sh\nBuild both MDT Linux packages with Docker Compose. Output: dist/\n'
  exit 0
fi
[[ $# -eq 0 ]] || { printf 'No arguments expected. Use --help for usage.\n' >&2; exit 1; }

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
"$script_dir/build-deb.sh"
"$script_dir/build-rpm.sh"
