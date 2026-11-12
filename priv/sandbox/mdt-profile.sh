# shellcheck shell=sh
# Written by MDT, read by every bash in the VM (through BASH_ENV and
# /etc/profile.d). Login shells reset PATH; restore the tools for Zed's
# environment probe, terminals, language servers, tasks and agents alike.
# Keep this POSIX compatible: /etc/profile can also be read by sh.
# /mnt/mdt/bin holds `mdt`, which agents ask MDT for access with.
for _mdt_bin in /mnt/mdt/bin /usr/local/share/cargo/bin "$HOME/.local/bin" \
  /cache/go/bin /cache/cargo/bin /cache/npm-global/bin \
  /usr/local/share/mise/shims /cache/mise/shims; do
  case ":$PATH:" in
    *:"$_mdt_bin":*) ;;
    *) PATH="$_mdt_bin:$PATH" ;;
  esac
done
unset _mdt_bin
export PATH

# Host writes to shared folders do not emit inotify events in the VM. Zed
# excludes virtiofs from automatic polling, so choose polling explicitly.
export ZED_FILE_WATCHER_MODE=poll
export ZED_FILE_WATCHER_POLL_MS=5000

# Placeholders are worthless outside MDT's proxy. Read this on every shell
# start, including after an MDT update changes the available grants.
if [ -r /mnt/mdt/env.sh ]; then
  # shellcheck source=/dev/null
  . /mnt/mdt/env.sh
fi
