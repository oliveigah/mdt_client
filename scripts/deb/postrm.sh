#!/bin/sh
# Runs as root after MDT's deb is removed: takes away what postinst.sh made.
set -e

case "${1:-}" in
  remove | purge)
    if [ -e /etc/apparmor.d/mdt-bwrap ]; then
      if command -v apparmor_parser > /dev/null 2>&1; then
        apparmor_parser --remove /etc/apparmor.d/mdt-bwrap 2> /dev/null || true
      fi
      rm -f /etc/apparmor.d/mdt-bwrap
    fi
    rm -f /usr/lib/mdt/bwrap
    rmdir /usr/lib/mdt 2> /dev/null || true
    ;;
esac

exit 0
