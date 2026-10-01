#!/usr/bin/env bash
# Starts driver.mjs, installing playwright-core outside the repository on
# first use. Arguments and stdin are handed to the driver.
#
# NODE, CHROME and MDT_DRIVER_CACHE override what is found.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="${MDT_DRIVER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/mdt-run-driver}"

# Node on PATH, or the one Zed ships, which is often the only one installed.
NODE="${NODE:-$(command -v node || ls -d "$HOME"/.local/share/zed/node/node-*/bin/node 2>/dev/null | tail -1 || true)}"
if [ ! -x "$NODE" ]; then
  echo "node not found; set NODE=/path/to/node" >&2
  exit 1
fi
export PATH="$(dirname "$NODE"):$PATH"

if [ ! -d "$CACHE/node_modules/playwright-core" ]; then
  echo "installing playwright-core into $CACHE" >&2
  mkdir -p "$CACHE"
  (cd "$CACHE" && npm init -y >/dev/null && npm install --silent --no-audit --no-fund playwright-core@1)
fi

export MDT_DRIVER_CACHE="$CACHE"
exec "$NODE" "$HERE/driver.mjs" "$@"
