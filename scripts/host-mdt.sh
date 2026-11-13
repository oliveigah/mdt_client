#!/usr/bin/env bash
# The MDT you use day to day, kept apart from the checkout agents work in.
#
# The agent sandbox's VM mounts this checkout read-write, and the MDT that runs
# the VM must not be built from it: a dev server reloads whatever is on disk,
# so an agent's half-done edit would run in the process holding its own VM.
# The host copy is a separate clone (not a worktree, whose git metadata would
# live in the shared .git) pinned to a commit you choose, with its own deps,
# _build and msb runtime. Never share it into the VM.
#
#   install [COMMIT]  clone or move the host copy to COMMIT (default: this
#                     checkout's HEAD) and build it; refuses while it runs
#   start             run the host MDT in the foreground (mix phx.server)
#   status            the host copy's commit, how far behind it is, and
#                     whether it runs
#
# Env: MDT_HOST_DIR (default ~/projects/mdt/mdt_host), PORT (default 4000).
set -Eeuo pipefail

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
host_dir="${MDT_HOST_DIR:-$HOME/projects/mdt/mdt_host}"
port="${PORT:-4000}"

die() { printf '%s\n' "$*" >&2; exit 1; }

# Dev servers whose working directory is the host copy.
host_pids() {
  local pid
  for pid in $(pgrep -f 'phx\.server' || true); do
    if [[ "$(readlink -f "/proc/$pid/cwd" 2>/dev/null)" == "$host_dir" ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

describe() { git -C "$1" log -1 --format='%h %s (%cr)' "${2:-HEAD}"; }

install() {
  local commit wanted have
  commit="$(git -C "$source_dir" rev-parse --verify --quiet "${1:-HEAD}^{commit}")" ||
    die "not a commit in $source_dir: ${1:-HEAD}"

  [[ -z "$(host_pids)" ]] || die "the host MDT is running (pid $(host_pids | xargs)); stop it first"

  if [[ -n "$(git -C "$source_dir" status --porcelain)" && -z "${1:-}" ]]; then
    printf 'Note: uncommitted changes in %s are not part of the host copy.\n' "$source_dir"
  fi

  if [[ ! -d "$host_dir/.git" ]]; then
    printf '==> cloning into %s\n' "$host_dir"
    git clone --quiet --no-hardlinks --no-checkout "$source_dir" "$host_dir"
  else
    [[ -z "$(git -C "$host_dir" status --porcelain --untracked-files=no)" ]] ||
      die "the host copy has local edits; it only ever runs commits. See: git -C $host_dir status"
    git -C "$host_dir" fetch --quiet --tags origin '+refs/heads/*:refs/remotes/origin/*'
  fi

  git -C "$host_dir" cat-file -e "$commit^{commit}" 2>/dev/null ||
    die "$commit is on no branch of $source_dir; put it on one first"
  git -C "$host_dir" -c advice.detachedHead=false checkout --quiet --detach "$commit"
  printf '==> host copy at %s\n' "$(describe "$host_dir")"

  # The msb runtime is built, not committed. Reuse this checkout's when it is
  # the version the host commit pins; build it otherwise.
  wanted="$(sed -n 's/^VERSION=//p' "$host_dir/scripts/build-microsandbox.sh" 2>/dev/null || true)"
  have="$(cat "$source_dir/priv/microsandbox/VERSION" 2>/dev/null || true)"
  if [[ -z "$wanted" ]]; then
    : # a commit from before MDT shipped its own msb
  elif [[ "$wanted" == "$have" ]]; then
    printf '==> msb runtime %s from %s\n' "$have" "$source_dir"
    rsync -a --delete "$source_dir/priv/microsandbox/" "$host_dir/priv/microsandbox/"
  else
    printf '==> building msb runtime %s (this checkout has %s)\n' "$wanted" "${have:-none}"
    (cd "$host_dir" && ./scripts/build-microsandbox.sh)
  fi

  # The asset tools are downloads; reuse this checkout's rather than fetch them.
  mkdir -p "$host_dir/_build"
  for tool in "$source_dir"/_build/esbuild-* "$source_dir"/_build/tailwind-*; do
    if [[ -f "$tool" && ! -e "$host_dir/_build/$(basename "$tool")" ]]; then
      cp -a "$tool" "$host_dir/_build/"
    fi
  done

  printf '==> building\n'
  (cd "$host_dir" && MIX_ENV=dev mix deps.get && MIX_ENV=dev mix assets.setup && MIX_ENV=dev mix compile)
  printf '\nReady. Start it with: %s start\n' "${BASH_SOURCE[0]}"
}

start() {
  [[ -d "$host_dir/.git" ]] || die "no host copy at $host_dir; run: ${BASH_SOURCE[0]} install"
  [[ -z "$(host_pids)" ]] || die "the host MDT is already running (pid $(host_pids | xargs))"

  local holder
  holder="$(ss -Hltnp "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)"
  if [[ -n "$holder" ]]; then
    die "port $port is taken by pid $holder (in $(readlink -f "/proc/$holder/cwd" 2>/dev/null || echo '?')); stop it first"
  fi

  printf '==> host MDT at %s\n' "$(describe "$host_dir")"
  cd "$host_dir"
  MIX_ENV=dev PORT="$port" exec mix phx.server
}

status() {
  [[ -d "$host_dir/.git" ]] || { printf 'No host copy at %s\n' "$host_dir"; return; }
  local commit behind pids
  commit="$(git -C "$host_dir" rev-parse HEAD)"
  printf 'host copy   %s\n            %s\n' "$host_dir" "$(describe "$host_dir")"
  if git -C "$source_dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
    behind="$(git -C "$source_dir" rev-list --count "$commit..HEAD")"
    printf 'checkout    %s (%s commits ahead of the host)\n' "$(describe "$source_dir")" "$behind"
  fi
  pids="$(host_pids | xargs)"
  printf 'running     %s\n' "${pids:+yes, pid $pids}${pids:-no}"
}

case "${1:-}" in
  install) shift; [[ $# -le 1 ]] || die "install takes at most one commit"; install "$@" ;;
  start) start ;;
  status) status ;;
  -h | --help | help | "") usage ;;
  *) die "unknown command: $1 (see --help)" ;;
esac
