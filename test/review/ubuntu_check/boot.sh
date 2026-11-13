#!/usr/bin/env bash
# Boots an Ubuntu cloud image under qemu, with KVM passed through so a VM
# can run in it, and waits until it takes SSH.
#
#     boot.sh DIR IMAGE [PORT]
#
# DIR gets the disk, the keys and the logs. Stop it with: kill $(cat DIR/qemu.pid)
set -eu
DIR=$1
IMAGE=$2
PORT=${3:-42222}
cd "$DIR"
[ -f key ] || ssh-keygen -q -t ed25519 -N "" -f key
cat > user-data <<USERDATA
#cloud-config
users:
  - name: mdt
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat key.pub)
package_update: true
packages: [bubblewrap, e2fsprogs, python3]
runcmd:
  - [sh, -c, "chmod 666 /dev/kvm; touch /var/tmp/ready"]
USERDATA
printf 'instance-id: mdt-check-%s\nlocal-hostname: mdt-check\n' "$(date +%s)" > meta-data
genisoimage -quiet -output seed.iso -volid cidata -joliet -rock user-data meta-data
rm -f disk.qcow2
qemu-img create -q -f qcow2 -b "$IMAGE" -F qcow2 disk.qcow2 24G
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 6G \
  -drive file=disk.qcow2,if=virtio -drive file=seed.iso,if=virtio,media=cdrom \
  -netdev user,id=net,hostfwd=tcp:127.0.0.1:"$PORT"-:22 -device virtio-net-pci,netdev=net \
  -display none -serial file:console.log -daemonize -pidfile qemu.pid
echo "qemu started, pid $(cat qemu.pid)"
for _ in $(seq 1 150); do
  if ssh -i key -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       -o ConnectTimeout=2 -o LogLevel=ERROR mdt@127.0.0.1 test -e /var/tmp/ready 2>/dev/null; then
    echo "ready"; exit 0
  fi
  read -r -t 2 _ < /dev/zero 2>/dev/null || true
done
echo "not ready in time"; tail -5 console.log; exit 1
