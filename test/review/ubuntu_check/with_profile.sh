#!/usr/bin/env bash
# Runs in the Ubuntu VM after inside.sh failed: installs an AppArmor profile
# and runs the same check again.
#
#     with_profile.sh WORK own-bwrap     a copy of bwrap at /opt/mdt/bwrap, with a profile of its own
#     with_profile.sh WORK launcher      a profile on the program that starts everything, bwrap as it comes
set -u
WORK=$1
HOW=$2
export HOME="$WORK/home" MSB_HOME="$WORK/home" MSB_PATH="$WORK/runtime/bin/msb" NO_COLOR=1
sudo mkdir -p /opt/mdt

case "$HOW" in
  own-bwrap)
    sudo cp /usr/bin/bwrap /opt/mdt/bwrap
    sudo tee /etc/apparmor.d/mdt-bwrap > /dev/null <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>

profile mdt-bwrap /opt/mdt/bwrap flags=(unconfined) {
  userns,
  include if exists <local/mdt-bwrap>
}
PROFILE
    sudo apparmor_parser -r /etc/apparmor.d/mdt-bwrap && echo "profile mdt-bwrap loaded"
    MDT_BWRAP=/opt/mdt/bwrap python3 "$WORK/msb_confine/relay_live.py" --work "$WORK" --mib 128 2>&1 | tail -40
    ;;
  launcher)
    # Stands in for MDT's own program: everything it starts keeps its profile.
    sudo cp /usr/bin/env /opt/mdt/launcher
    sudo tee /etc/apparmor.d/mdt-launcher > /dev/null <<'PROFILE'
abi <abi/4.0>,
include <tunables/global>

profile mdt-launcher /opt/mdt/launcher flags=(unconfined) {
  userns,
  include if exists <local/mdt-launcher>
}
PROFILE
    sudo apparmor_parser -r /etc/apparmor.d/mdt-launcher && echo "profile mdt-launcher loaded"
    /opt/mdt/launcher python3 "$WORK/msb_confine/relay_live.py" --work "$WORK" --mib 128 2>&1 | tail -40
    ;;
esac
