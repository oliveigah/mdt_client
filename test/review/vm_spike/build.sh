#!/bin/sh
# Builds the spike's root disk: an Alpine image from podman, the host
# kernel's modules the VM needs, and the guest scripts.
#   test/review/vm_spike/build.sh [WORKDIR]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=${1:-/var/tmp/mdt-vmspike}
kernel=$(uname -r)
mkdir -p "$work"
podman build -q -t localhost/mdt-vmspike:latest -f "$here/Containerfile" "$here" >/dev/null
container=$(podman create localhost/mdt-vmspike:latest)
rm -rf "$work/root" && mkdir -p "$work/root"
podman export "$container" | tar -x -C "$work/root" --no-same-owner
podman rm "$container" >/dev/null

mkdir -p "$work/root/modules" "$work/root/opt"
: >"$work/root/modules/order"
for module in fuse virtiofs vsock vmw_vsock_virtio_transport dummy nf_conntrack nf_tables nf_nat nft_chain_nat nft_redir virtio_net; do
  modprobe --ignore-install --show-depends "$module" | while read -r kind path _; do
    [ "$kind" = insmod ] || continue
    name=$(basename "$path" .xz)
    name=${name%.zst}
    if [ ! -e "$work/root/modules/$name" ]; then
      case $path in
        *.xz) xz -dc "$path" >"$work/root/modules/$name" ;;
        *.zst) zstd -dc "$path" >"$work/root/modules/$name" ;;
        *) cp "$path" "$work/root/modules/$name" ;;
      esac
      echo "$name" >>"$work/root/modules/order"
    fi
  done
done
install -m 0755 "$here/guest/init" "$work/root/init"
install -m 0644 "$here/guest/egress.nft" "$work/root/etc/egress.nft"
install -m 0644 "$here"/guest/*.py "$work/root/opt/"
rm -f "$work/root.img"
mke2fs -q -t ext4 -E root_owner=0:0 -d "$work/root" "$work/root.img" 2G
cp "/lib/modules/$kernel/vmlinuz" "$work/vmlinuz"
du -sh "$work/root" "$work/root.img" | sed 's/^/  /'
cat "$work/root/modules/order" | tr '\n' ' '; echo
