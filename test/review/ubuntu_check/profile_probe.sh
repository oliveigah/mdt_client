#!/usr/bin/env bash
# Runs in the Ubuntu VM after postinst.sh: what the profile lets the inside
# of MDT's bwrap do, and what it doesn't.
B=/usr/lib/mdt/bwrap
inside() { "$B" --unshare-user --unshare-net --unshare-pid --uid 0 --gid 0 --cap-add ALL \
  --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
  --proc /proc --dev /dev --tmpfs /tmp -- "$@" 2>&1; }
echo "label inside:        $(inside cat /proc/self/attr/current)"
echo "net_admin (allowed): $(inside sh -c 'ip link set lo up && ip route add default dev lo && echo yes')"
echo "chown (refused):     $(inside sh -c 'touch /tmp/x && chown 1:1 /tmp/x && echo DONE' | tail -1)"
echo "mknod (refused):     $(inside sh -c 'mknod /tmp/null c 1 3 && echo DONE' | tail -1)"
echo "net_raw (refused):   $(inside sh -c 'python3 -c "import socket; socket.socket(socket.AF_INET, socket.SOCK_RAW, 1); print(\"DONE\")"' | tail -1)"
echo "system bwrap, same:  $(/usr/bin/bwrap --unshare-user --unshare-net --uid 0 --gid 0 --cap-add ALL --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/sbin /sbin --symlink usr/lib /lib --symlink usr/lib64 /lib64 --proc /proc --dev /dev -- sh -c 'ip route add default dev lo && echo yes' 2>&1 | tail -1)"
