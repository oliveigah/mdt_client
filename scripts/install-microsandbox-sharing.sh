#!/usr/bin/env bash
# Run on the host. Replace only the existing v0.7.14 runtime, keeping a backup.
# The running VM stays untouched until it is stopped and started in MDT.
set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
  echo "This installer targets Linux hosts." >&2
  exit 1
fi

PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CANDIDATE=$PROJECT/tmp/microsandbox-sharing-runtime/msb
CHECKSUMS=$PROJECT/tmp/microsandbox-sharing-runtime/checksums.sha256
SANDBOX=${1:-}

if [[ ${MDT_SANDBOX:-} == 1 ]] || mountpoint -q /mnt/mdt 2>/dev/null; then
  echo "Run this script in a host terminal, outside the sandbox." >&2
  exit 1
fi
if [[ -z "$SANDBOX" ]]; then
  echo "Usage: bash $0 SANDBOX_NAME [EXISTING_MSB_PATH]" >&2
  exit 1
fi

DESTINATION=${2:-$(command -v msb || true)}
if [[ -z "$DESTINATION" && -x "$HOME/.microsandbox/bin/msb" ]]; then
  DESTINATION=$HOME/.microsandbox/bin/msb
fi
if [[ "$DESTINATION" == */shims/* ]]; then
  DESTINATION=$(mise which msb)
fi
if [[ -z "$DESTINATION" || ! -f "$DESTINATION" ]]; then
  echo "Could not find the installed runtime. Pass its path as the second argument." >&2
  exit 1
fi
DESTINATION=$(realpath -- "$DESTINATION")
if [[ $("$DESTINATION" --version) != 'msb 0.7.14' ]]; then
  echo "This patch targets msb 0.7.14. Refusing to replace a different version." >&2
  exit 1
fi

# The VM-built candidate is useful for a live check on compatible Linux hosts.
# If its libc/architecture differs, build natively rather than installing it.
if [[ -f "$CANDIDATE" && -f "$CHECKSUMS" ]] && sha256sum --check --status "$CHECKSUMS"; then
  # Guest chmod can be virtualized; grant the host owner execute permission too.
  chmod u+x -- "$CANDIDATE"
fi
if [[ ! -x "$CANDIDATE" || ! -f "$CHECKSUMS" ]] ||
  [[ $(cat "$PROJECT/tmp/microsandbox-sharing-runtime/build-profile" 2>/dev/null || true) != release ]] ||
  ! sha256sum --check --status "$CHECKSUMS" ||
  ! "$CANDIDATE" --version >/dev/null 2>&1; then
  bash "$PROJECT/scripts/build-microsandbox-sharing.sh"
fi
sha256sum --check --status "$CHECKSUMS"
if [[ $("$CANDIDATE" --version) != 'msb 0.7.14' ]]; then
  echo "Unexpected candidate runtime version." >&2
  exit 1
fi

BACKUP=$DESTINATION.before-mdt-sharing
if [[ ! -e "$BACKUP" ]]; then
  cp -p -- "$DESTINATION" "$BACKUP"
fi
TEMPORARY=$(mktemp "$(dirname -- "$DESTINATION")/.msb-sharing.XXXXXX")
trap 'rm -f -- "$TEMPORARY"' EXIT
install -m 755 -- "$CANDIDATE" "$TEMPORARY"
mv -f -- "$TEMPORARY" "$DESTINATION"

MSB_BACKEND=local "$DESTINATION" modify "$SANDBOX" \
  --env ZED_FILE_WATCHER_MODE=poll --env ZED_FILE_WATCHER_POLL_MS=5000

echo "Installed patched runtime: $DESTINATION"
echo "Backup: $BACKUP"
echo "For this project's intended access scope, set MDT's shares to only: $PROJECT (read-write)."
echo "Remove the broader mdt parent and msb_test shares before adding the project."
echo "Apply changed shares with Recreate in MDT, keeping Home and Cache, then reconnect Zed."
echo "If shares were already narrowed, stop/start is enough to activate the runtime. No image rebuild is needed."
echo "After restarting, run on the host:"
printf 'python3 %q check --sandbox %q --msb %q\n' \
  "$PROJECT/scripts/sandbox_shared_fs_probe.py" "$SANDBOX" "$DESTINATION"
