#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  printf 'Usage: ./scripts/build-rpm.sh\nBuild the MDT .rpm with Docker Compose. Output: dist/\n'
  printf 'Set PACKAGE_PLATFORM to override the default linux/amd64 target.\n'
  exit 0
fi
[[ $# -eq 0 ]] || { printf 'No arguments expected. Use --help for usage.\n' >&2; exit 1; }

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
compose=(docker compose --project-directory "$project_dir" --file "$project_dir/compose.packages.yaml")

command -v docker >/dev/null || { printf 'Docker is required. See README.md.\n' >&2; exit 1; }
docker info >/dev/null || { printf 'Docker is not running or is not accessible.\n' >&2; exit 1; }
docker compose version >/dev/null || { printf 'The Docker Compose plugin is required.\n' >&2; exit 1; }

cleanup() {
  "${compose[@]}" rm --force --stop rpm >/dev/null 2>&1 || true
}
trap cleanup EXIT

printf 'Building the MDT RPM package for %s...\n' "${PACKAGE_PLATFORM:-linux/amd64}"
"${compose[@]}" build rpm
"${compose[@]}" create --force-recreate rpm >/dev/null
container_id="$("${compose[@]}" ps --all --quiet rpm)"
[[ -n "$container_id" ]] || { printf 'Could not create the artifact container.\n' >&2; exit 1; }

mkdir -p "$project_dir/dist"
docker cp "$container_id:/out/." "$project_dir/dist/"
printf '\nRPM package ready in %s/dist/\n' "$project_dir"
