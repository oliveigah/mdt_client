#!/bin/sh
# Same steps in one folder; times from /proc/uptime (10 ms steps).
now() { cut -d' ' -f1 /proc/uptime; }
step() { name="$1"; shift; a=$(now); "$@"; b=$(now); echo "$name $(echo "$a $b" | awk '{printf "%.2f", $2-$1}')"; }
create() { i=0; while [ $i -lt 500 ]; do mkdir -p d$i; j=0; while [ $j -lt 20 ]; do echo "content $i $j" > d$i/f$j; j=$((j+1)); done; i=$((i+1)); done; sync; }
readall() { for d in d*; do cat $d/* > /dev/null; done; }
big() { dd if=/dev/zero of=big bs=1M count=1024 conv=fsync 2>/dev/null; }
readbig() { dd if=big of=/dev/null bs=1M 2>/dev/null; }
remove() { rm -rf d* big; sync; }
mkdir -p "$1/bench" && cd "$1/bench" || exit 1
step "create 10,000 files" create
step "read them" readall
step "write 1 GiB + fsync" big
echo 3 > /proc/sys/vm/drop_caches
step "read 1 GiB back" readbig
step "remove everything" remove
cd .. && rmdir bench
