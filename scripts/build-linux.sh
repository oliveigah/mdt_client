#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/build-linux.sh\nBuild an AppImage in Ubuntu 22.04 using Podman or Docker. Output: dist/\n'
  exit 0
fi
[[ $# -eq 0 ]] || { printf 'No arguments expected. Use --help for usage.\n' >&2; exit 1; }

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$project_dir"

if command -v podman >/dev/null; then
  engine=podman
elif command -v docker >/dev/null; then
  engine=docker
else
  printf 'Install Podman or Docker first. See README.md.\n' >&2
  exit 1
fi
"$engine" info >/dev/null || { printf 'Cannot use %s. Check that it is running and accessible.\n' "$engine" >&2; exit 1; }

# Building on an older Ubuntu baseline avoids depending on Fedora's newer glibc.
image=localhost/mdt-appimage:latest
printf 'Building MDT AppImage with %s (Ubuntu 22.04)...\n' "$engine"
"$engine" build --file scripts/appimage.Dockerfile --tag "$image" .

# Copy only the finished artifact out; host dependencies and build caches stay separate.
container="$("$engine" create "$image" /unused)"
trap '"$engine" rm "$container" >/dev/null' EXIT
mkdir -p dist
"$engine" cp "$container:/out/." dist/

printf '\nAppImage ready in %s/dist/\nShare the .AppImage file. No package installation is needed.\n' "$project_dir"
