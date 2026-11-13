#!/usr/bin/env bash
# Runs in the Ubuntu VM, as an ordinary user: does the bubble MDT starts
# msb in work here, and with which AppArmor profile if not?
#
#     inside.sh WORK
#
# WORK holds runtime/ (msb, mdt-relay, lib) and msb_confine/ (the scripts).
set -u
WORK=$1
export HOME="$WORK/home" MSB_HOME="$WORK/home" MSB_PATH="$WORK/runtime/bin/msb" NO_COLOR=1
mkdir -p "$HOME"

echo "== The machine"
. /etc/os-release && echo "$PRETTY_NAME, kernel $(uname -r), bwrap $(bwrap --version | cut -d' ' -f2)"
echo "apparmor_restrict_unprivileged_userns = $(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo absent)"
echo "profiles naming bwrap: $(ls /etc/apparmor.d 2>/dev/null | grep -i bwrap | tr '\n' ' ')"
ls -l /dev/kvm

bubble() { # bubble BWRAP: the namespaces and the two capabilities MDT asks for
  "$1" --unshare-user --unshare-pid --unshare-net --unshare-ipc --unshare-uts --unshare-cgroup \
    --as-pid-1 --uid 0 --gid 0 --cap-add CAP_NET_ADMIN --cap-add CAP_SETPCAP \
    --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib \
    --symlink usr/lib64 /lib64 --proc /proc --dev /dev --tmpfs /tmp --tmpfs /run \
    --ro-bind "$WORK/runtime" /mdt/runtime --chdir / --clearenv \
    -- /mdt/runtime/bin/mdt-relay --sockets /tmp --name probe -- /usr/bin/true 2>&1
}

echo
echo "== 1. The system's bwrap, as it comes"
bubble bwrap | head -5
echo "exit ${PIPESTATUS[0]}"

echo
echo "== 2. msb's image"
"$MSB_PATH" pull alpine > "$WORK/pull.out" 2>&1; echo "msb pull alpine: exit $? $(tail -1 "$WORK/pull.out" | cut -c1-80)"

echo
echo "== 3. The whole check, with the system's bwrap"
python3 "$WORK/msb_confine/relay_live.py" --work "$WORK" --mib 128 2>&1 | tail -40
