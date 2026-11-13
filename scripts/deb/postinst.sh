#!/bin/sh
# Runs as root after MDT's deb is installed or upgraded. Also by hand, for an
# MDT run from source on Ubuntu: sudo sh scripts/deb/postinst.sh
#
# The Agent Sandbox runs its VM inside a bubble that bubblewrap makes: user,
# mount and network namespaces of its own, where MDT's relay adds one route
# into loopback and then gives up every capability. Ubuntu (24.04 and later)
# lets a program hold capabilities in a user namespace only when an AppArmor
# profile says so, and its own profile for /usr/bin/bwrap says no. So MDT
# gets a copy of the system's bwrap under a path of its own, with a profile
# that allows what the bubble needs and nothing more: what runs inside may
# hold CAP_NET_ADMIN and CAP_SETPCAP, in namespaces that hold nothing of the
# machine's network.
#
# Where AppArmor doesn't restrict user namespaces (Debian, or Ubuntu before
# 24.04) nothing is installed, and MDT uses the system's bwrap as it is.
set -e

OWN=/usr/lib/mdt/bwrap
PROFILE=/etc/apparmor.d/mdt-bwrap
SWITCH=/proc/sys/kernel/apparmor_restrict_unprivileged_userns

if [ ! -e "$SWITCH" ] || ! command -v apparmor_parser > /dev/null 2>&1 || [ ! -x /usr/bin/bwrap ]; then
  exit 0
fi

# The system's own bwrap, as it is today: installing MDT again refreshes it.
install -D -m 0755 /usr/bin/bwrap "$OWN"

cat > "$PROFILE" <<'PROFILE'
# Installed by MDT (scripts/deb/postinst.sh). The Agent Sandbox starts its VM
# through this copy of bwrap. Modelled on Ubuntu's bwrap-userns-restrict:
# bwrap sets the namespaces up, and what it starts runs as mdt-bubble, which
# may hold the two capabilities MDT's relay uses once and then gives up.
abi <abi/4.0>,
include <tunables/global>

profile mdt-bwrap /usr/lib/mdt/bwrap flags=(attach_disconnected,mediate_deleted) {
  allow capability,
  allow file rwlkm /{**,},
  allow network,
  allow unix,
  allow ptrace,
  allow signal,
  allow mqueue,
  allow io_uring,
  allow userns,
  allow mount,
  allow umount,
  allow pivot_root,
  allow dbus,

  allow pix /** -> &mdt-bwrap//&mdt-bubble,

  include if exists <local/mdt-bwrap>
}

profile mdt-bubble flags=(attach_disconnected,mediate_deleted) {
  allow file rwlkm /{**,},
  allow network,
  allow unix,
  allow ptrace,
  allow signal,
  allow mqueue,
  allow io_uring,
  allow userns,
  allow mount,
  allow umount,
  allow pivot_root,
  allow dbus,

  allow pix /** -> &mdt-bubble,

  # One route into loopback (net_admin), then the bounding set is emptied
  # (setpcap). Any other capability is refused, and logged.
  allow capability net_admin,
  allow capability setpcap,
  audit deny capability audit_control,
  audit deny capability audit_read,
  audit deny capability audit_write,
  audit deny capability block_suspend,
  audit deny capability bpf,
  audit deny capability checkpoint_restore,
  audit deny capability chown,
  audit deny capability dac_override,
  audit deny capability dac_read_search,
  audit deny capability fowner,
  audit deny capability fsetid,
  audit deny capability ipc_lock,
  audit deny capability ipc_owner,
  audit deny capability kill,
  audit deny capability lease,
  audit deny capability linux_immutable,
  audit deny capability mac_admin,
  audit deny capability mac_override,
  audit deny capability mknod,
  audit deny capability net_bind_service,
  audit deny capability net_broadcast,
  audit deny capability net_raw,
  audit deny capability perfmon,
  audit deny capability setfcap,
  audit deny capability setgid,
  audit deny capability setuid,
  audit deny capability sys_admin,
  audit deny capability sys_boot,
  audit deny capability sys_chroot,
  audit deny capability sys_module,
  audit deny capability sys_nice,
  audit deny capability sys_pacct,
  audit deny capability sys_ptrace,
  audit deny capability sys_rawio,
  audit deny capability sys_resource,
  audit deny capability sys_time,
  audit deny capability sys_tty_config,
  audit deny capability syslog,
  audit deny capability wake_alarm,

  include if exists <local/mdt-bubble>
}
PROFILE

# A system whose AppArmor can't read the profile keeps running without it:
# MDT then says on its Setup page that the bubble can't be made.
if ! apparmor_parser --replace "$PROFILE" 2> /dev/null; then
  rm -f "$PROFILE"
fi

exit 0
