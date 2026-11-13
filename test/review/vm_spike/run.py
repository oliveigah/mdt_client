#!/usr/bin/env python3
"""Boots the spike VM under QEMU and checks what a VM layer of MDT's own would
have to do. Nothing here uses msb.

    test/review/vm_spike/build.sh
    test/review/vm_spike/run.py                 # no network card, egress over vsock
    test/review/vm_spike/run.py --confine       # same, QEMU inside bwrap with no network
    test/review/vm_spike/run.py --net nic       # reference: virtio-net behind passt
    test/review/vm_spike/run.py --cache never   # virtiofsd without caching

The host side stands in for MDT: a CONNECT proxy and a DNS forwarder that only
the VM's vsock can reach, and a source/sink for throughput.
"""
import argparse
import ipaddress
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time

CID = 4242
TEST_ADDRESS = "10.255.255.1"  # the proxy sends this one to the host's sink
SINK_PORT = 6001
VIRTIOFSD = "/usr/libexec/virtiofsd"

connects = []
lookups = []
results = []


def report(name, value):
    results.append((name, value))
    print(f"  {name:<58} {value}", flush=True)


def recv_exact(conn, count):
    data = b""
    while len(data) < count:
        more = conn.recv(count - len(data))
        if not more:
            raise OSError("closed")
        data += more
    return data


def pump(source, sink):
    buffer = bytearray(262_144)
    view = memoryview(buffer)
    try:
        while True:
            count = source.recv_into(buffer)
            if not count:
                break
            sink.sendall(view[:count])
    except OSError:
        pass
    try:
        sink.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def source_sink(conn):
    with conn:
        try:
            mode = recv_exact(conn, 1)
            size = struct.unpack("!Q", recv_exact(conn, 8))[0]
            if mode == b"D":
                chunk = memoryview(bytes(1024 * 1024))
                left = size
                while left:
                    count = min(left, len(chunk))
                    conn.sendall(chunk[:count])
                    left -= count
            else:
                buffer = bytearray(1024 * 1024)
                got = 0
                while got < size:
                    count = conn.recv_into(buffer)
                    if not count:
                        break
                    got += count
                conn.sendall(b"k")
        except OSError:
            pass


def egress(conn):
    """What MDT's Egress.Connection does first: read `CONNECT ip:port`."""
    try:
        head = b""
        while b"\r\n\r\n" not in head:
            data = conn.recv(4096)
            if not data:
                return conn.close()
            head += data
        target = head.split(b"\r\n", 1)[0].decode().split()[1]
        address, port = target.rsplit(":", 1)
        connects.append(target)
        if address == TEST_ADDRESS:
            destination = ("127.0.0.1", int(port))
        elif not ipaddress.ip_address(address).is_global:
            conn.sendall(b"HTTP/1.1 403 Forbidden\r\n\r\n")
            return conn.close()
        else:
            destination = (address, int(port))
        try:
            upstream = socket.create_connection(destination, timeout=10)
        except OSError:
            conn.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return conn.close()
        upstream.settimeout(None)
        upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        conn.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        up = threading.Thread(target=pump, args=(conn, upstream), daemon=True)
        up.start()
        pump(upstream, conn)
        up.join()
        upstream.close()
        conn.close()
    except OSError:
        conn.close()


def resolver():
    with open("/etc/resolv.conf") as file:
        for line in file:
            parts = line.split()
            if len(parts) > 1 and parts[0] == "nameserver":
                return parts[1]
    return "127.0.0.53"


def qname(query):
    labels, at = [], 12
    while at < len(query) and query[at]:
        labels.append(query[at + 1 : at + 1 + query[at]].decode(errors="replace"))
        at += 1 + query[at]
    return ".".join(labels)


def dns(conn):
    with conn:
        try:
            size = struct.unpack("!H", recv_exact(conn, 2))[0]
            query = recv_exact(conn, size)
            lookups.append(qname(query))
            server = resolver()
            family = socket.AF_INET6 if ":" in server else socket.AF_INET
            with socket.socket(family, socket.SOCK_DGRAM) as upstream:
                upstream.settimeout(5)
                upstream.sendto(query, (server, 53))
                answer, _ = upstream.recvfrom(65536)
            conn.sendall(struct.pack("!H", len(answer)) + answer)
        except OSError:
            pass


def listen(family, address, handler, only_cid=None):
    listener = socket.socket(family, socket.SOCK_STREAM)
    if family == socket.AF_INET:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(address)
    listener.listen(256)

    def loop():
        while True:
            conn, peer = listener.accept()
            # A host vsock listener is reachable from every VM on the machine
            # that uses the kernel's vhost-vsock, so the peer is checked.
            if only_cid is not None and peer[0] != only_cid:
                conn.close()
                continue
            threading.Thread(target=handler, args=(conn,), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()


def guest(command, timeout=900):
    conn = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    conn.connect((CID, 5000))
    conn.sendall(command.encode() + b"\n")
    output = b""
    while True:
        data = conn.recv(65536)
        if not data:
            break
        output += data
    conn.close()
    text = output.decode(errors="replace")
    body, _, code = text.rpartition("\n__EXIT__ ")
    return int(code.strip() or 1), body.strip()


class QMP:
    def __init__(self, path):
        self.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.conn.connect(path)
        self.file = self.conn.makefile("rw")
        self.file.readline()
        self.command("qmp_capabilities")

    def command(self, name, **arguments):
        self.file.write(json.dumps({"execute": name, "arguments": arguments}) + "\n")
        self.file.flush()
        while True:
            reply = json.loads(self.file.readline())
            if "return" in reply or "error" in reply:
                return reply


def virtiofsd(work, name, cache):
    socket_path = f"{work}/{name}.sock"
    if os.path.exists(socket_path):
        os.remove(socket_path)
    os.makedirs(f"{work}/{name}", exist_ok=True)
    process = subprocess.Popen(
        [VIRTIOFSD, f"--socket-path={socket_path}", f"--shared-dir={work}/{name}", f"--cache={cache}"],
        stdout=open(f"{work}/{name}.log", "w"),
        stderr=subprocess.STDOUT,
    )
    for _ in range(500):
        if os.path.exists(socket_path):
            return process
        time.sleep(0.01)
    sys.exit(f"virtiofsd did not start, see {work}/{name}.log")


def confinement(work):
    """QEMU sees /usr, its work folder and two devices. No home, no network."""
    return [
        "bwrap", "--unshare-user", "--unshare-net", "--unshare-pid", "--unshare-ipc", "--unshare-uts",
        "--die-with-parent", "--new-session",
        "--ro-bind", "/usr", "/usr", "--symlink", "usr/lib64", "/lib64", "--symlink", "usr/lib", "/lib",
        "--symlink", "usr/bin", "/bin", "--ro-bind", "/etc/ld.so.cache", "/etc/ld.so.cache",
        "--proc", "/proc", "--dev", "/dev", "--dev-bind", "/dev/kvm", "/dev/kvm",
        "--dev-bind", "/dev/vhost-vsock", "/dev/vhost-vsock",
        "--tmpfs", "/tmp", "--bind", work, work, "--chdir", work,
    ]  # fmt: skip


def qemu(work, net, confine):
    command = [
        "qemu-system-x86_64", "-M", "q35,accel=kvm,memory-backend=mem", "-cpu", "host", "-smp", "4", "-m", "4G",
        "-object", "memory-backend-memfd,id=mem,size=4G,share=on",
        "-nodefaults", "-no-user-config", "-display", "none", "-no-reboot",
        "-sandbox", "on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny",
        "-kernel", f"{work}/vmlinuz",
        "-drive", f"file={work}/root.img,format=raw,if=none,id=root,cache=unsafe",
        "-device", "virtio-blk-pci,drive=root",
        "-serial", f"file:{work}/console.log",
        "-chardev", f"socket,id=share,path={work}/share.sock",
        "-device", "vhost-user-fs-pci,chardev=share,tag=share",
        "-device", f"vhost-vsock-pci,guest-cid={CID}",
        "-device", "pcie-root-port,id=port1,chassis=1",
        "-qmp", f"unix:{work}/qmp.sock,server=on,wait=off",
    ]  # fmt: skip
    append = "root=/dev/vda rw console=ttyS0 init=/init panic=-1 quiet"
    if net == "nic":
        command += ["-netdev", f"stream,id=net,server=off,addr.type=unix,addr.path={work}/passt.sock",
                    "-device", "virtio-net-pci,netdev=net"]  # fmt: skip
        append += " spike.net=nic"
    command += ["-append", append]
    return (confinement(work) if confine else []) + command


def boot(work, net, confine):
    started = time.monotonic()
    process = subprocess.Popen(qemu(work, net, confine), stdout=open(f"{work}/qemu.log", "w"), stderr=subprocess.STDOUT)
    while time.monotonic() - started < 60:
        if process.poll() is not None:
            sys.exit(f"QEMU exited, see {work}/qemu.log and {work}/console.log")
        try:
            code, _ = guest("true", timeout=1)
            if code == 0:
                return process, time.monotonic() - started
        except OSError:
            time.sleep(0.01)
    process.kill()
    sys.exit(f"the VM's agent never answered, see {work}/console.log")


def check_structure(work, confine):
    print("\nWhat the VM has")
    _, links = guest("ls /sys/class/net | tr '\\n' ' '")
    report("network interfaces in the VM", links)
    _, pci = guest("for d in /sys/bus/pci/devices/*; do cat $d/class; done | sort | uniq -c | tr -s ' \\n' ' '")
    report("PCI device classes (0x0200 would be a network card)", pci)
    if confine:
        probe = subprocess.run(
            confinement(work) + ["sh", "-c", "tail -n +3 /proc/net/dev | cut -d: -f1 | tr '\\n' ' '; echo '|'; ls / | tr '\\n' ' '; echo '|'; ls /home 2>&1 | head -1"],
            capture_output=True, text=True,
        )  # fmt: skip
        report("what QEMU's own sandbox sees (interfaces | / | /home)", " ".join(probe.stdout.split()) or probe.stderr.strip())


def check_egress():
    print("\nEgress with no network card")
    code, out = guest("curl -sS -o /dev/null -m 20 -w '%{http_code} via %{remote_ip}:%{remote_port} in %{time_total}s' https://example.com/")
    report("curl https://example.com/", out)
    code, out = guest(
        "python3 -c \"import socket; s=socket.create_connection(('github.com',22),10); print(s.recv(64).decode().strip())\""
    )
    report("server speaks first, github.com:22", out)
    report("CONNECT lines the host saw", ", ".join(connects[-2:]))
    report("names the host saw looked up", ", ".join(sorted(set(lookups))))
    code, out = guest("python3 /opt/udp.py")
    report("UDP straight to 1.1.1.1:53", out[:70])
    guest("pkill -f /opt/relay.py; sleep 0.2")
    code, out = guest("curl -sS -o /dev/null -m 5 https://93.184.215.14/ 2>&1 | tail -1")
    report("with the VM's relay killed by root in the VM", out[:70])
    guest("nft flush ruleset; sleep 0.1")
    code, out = guest("curl -sS -o /dev/null -m 5 https://93.184.215.14/ 2>&1 | tail -1")
    report("and its nftables rules flushed", out[:70])
    guest("nft -f /etc/egress.nft; (python3 /opt/relay.py >/tmp/relay.log 2>&1 &) ; sleep 0.5")


def check_throughput(net, mib):
    print(f"\nThroughput, {mib} MiB each way (MiB/s)")
    if net == "nic":
        _, gateway = guest("ip route | awk '/default/{print $3}'")
        for direction in ("down", "up"):
            _, out = guest(f"python3 /opt/bench.py tcp {direction} {gateway} {SINK_PORT} {mib}")
            report(f"virtio-net + passt, {direction}", out.split()[-1] if out else "failed")
        return
    for direction in ("down", "up"):
        _, out = guest(f"python3 /opt/bench.py vsock {direction} 2 6000 {mib}")
        report(f"vsock stream, VM <-> host, {direction}", out.split()[-1] if out else "failed")
    for direction in ("down", "up"):
        _, out = guest(f"python3 /opt/bench.py tcp {direction} {TEST_ADDRESS} {SINK_PORT} {mib}")
        report(f"TCP in VM -> relay -> vsock -> host proxy -> TCP, {direction}", out.split()[-1] if out else out)


def check_coherence(work):
    print("\nShared folder: the host replaces a file, the VM reads it at once")
    folder = f"{work}/share/coherence"
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    with open(f"{folder}/file", "w") as file:
        file.write("v0\n")
    guest("cat /mnt/share/coherence/file")
    fresh = stale = errors = 0
    slowest = 0.0
    samples = []
    for index in range(1, 201):
        with open(f"{folder}/file.tmp", "w") as file:
            file.write(f"v{index}\n")
        os.replace(f"{folder}/file.tmp", f"{folder}/file")
        replaced = time.monotonic()
        code, out = guest("cat /mnt/share/coherence/file")
        if code != 0:
            errors += 1
            samples.append(out)
        elif out == f"v{index}":
            fresh += 1
        else:
            stale += 1
            while guest("cat /mnt/share/coherence/file")[1] != f"v{index}" and time.monotonic() - replaced < 10:
                time.sleep(0.02)
            slowest = max(slowest, time.monotonic() - replaced)
    report("200 replacements: new content / old content / error", f"{fresh} / {stale} / {errors}")
    if stale:
        report("longest the old content was served (s)", f"{slowest:.2f}")
    if samples:
        report("first error", samples[0][:70])

    repo = f"{work}/share/repo"
    shutil.rmtree(repo, ignore_errors=True)
    os.makedirs(repo)
    git = ["git", "-C", repo, "-c", "user.name=spike", "-c", "user.email=spike@invalid", "-c", "commit.gpgsign=false"]
    subprocess.run(git + ["init", "-q"], check=True)
    for index in range(64):
        with open(f"{repo}/file{index}", "w") as file:
            file.write(f"{index}\n")
    subprocess.run(git + ["add", "-A"], check=True)
    subprocess.run(git + ["commit", "-q", "-m", "start"], check=True)
    guest("git -C /mnt/share/repo ls-files | wc -l")
    fresh = older = broken = 0
    for index in range(1, 101):
        with open(f"{repo}/new{index}", "w") as file:
            file.write(f"{index}\n")
        subprocess.run(git + ["add", f"new{index}"], check=True)
        code, out = guest("git -C /mnt/share/repo ls-files | wc -l")
        if out == str(64 + index):
            fresh += 1
        elif out.isdigit() and 64 <= int(out) < 64 + index:
            older += 1
        else:
            broken += 1
            samples.append(out)
    report("100 host `git add`s, VM `git ls-files`: new / an older index / broken", f"{fresh} / {older} / {broken}")
    time.sleep(1.2)
    report("the VM's count 1.2 s after the last one (164 expected)", guest("git -C /mnt/share/repo ls-files | wc -l")[1])
    code, out = guest("cd /mnt/share/repo && git status --porcelain | wc -l && git fsck 2>&1 | tail -1")
    report("VM `git status` lines, `git fsck`", out.replace("\n", ", ")[:70])
    seen = {}

    def watch():
        seen["out"] = guest("python3 /opt/watch.py /mnt/share/coherence 3")[1]

    watcher = threading.Thread(target=watch)
    watcher.start()
    time.sleep(1)
    with open(f"{folder}/created-by-host", "w") as file:
        file.write("x\n")
    watcher.join()
    report("inotify in the VM for a file the host creates", seen["out"].split("\n")[-1])


def cpu_seconds(pid):
    """CPU used so far by a process and its children (virtiofsd forks)."""
    ticks = os.sysconf("SC_CLK_TCK")
    parents, total = {}, {}
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                fields = open(f"/proc/{entry}/stat").read().rsplit(")", 1)[1].split()
            except OSError:
                continue
            parents[int(entry)] = int(fields[1])
            total[int(entry)] = (int(fields[11]) + int(fields[12])) / ticks
    family = {pid}
    grew = True
    while grew:
        more = {child for child, parent in parents.items() if parent in family} - family
        grew = bool(more)
        family |= more
    return sum(total.get(member, 0) for member in family)


def family_of(pid):
    parents, names = {}, {}
    for entry in os.listdir("/proc"):
        if entry.isdigit():
            try:
                name, rest = open(f"/proc/{entry}/stat").read().split("(", 1)[1].rsplit(")", 1)
            except OSError:
                continue
            parents[int(entry)] = int(rest.split()[1])
            names[int(entry)] = name
    family = [pid]
    for member in family:
        family += [child for child, parent in parents.items() if parent == member]
    return [(member, names.get(member, "?")) for member in family]


def confinement_of(label, pid):
    status = {}
    for line in open(f"/proc/{pid}/status"):
        key, _, value = line.partition(":")
        status[key] = value.strip()
    own = []
    for name in ("user", "mnt", "net", "pid", "ipc"):
        try:
            if os.readlink(f"/proc/{pid}/ns/{name}") != os.readlink(f"/proc/self/ns/{name}"):
                own.append(name)
        except OSError:
            own.append(f"{name}?")
    try:
        root = os.readlink(f"/proc/{pid}/root")
    except OSError:
        root = "not readable from outside"
    report(label, f"seccomp {status['Seccomp']}, no_new_privs {status['NoNewPrivs']}, own namespaces: {' '.join(own) or 'none'}")
    report(f"{label}: groups, root", f"{status['Groups'] or '-'}, {root}")


def check_confinement(vm, daemon):
    print("\nHow the host processes are confined (seccomp 2 = filtered)")
    for pid, name in family_of(vm.pid):
        if name.startswith("qemu-system"):
            confinement_of("QEMU", pid)
    workers = [pid for pid, name in family_of(daemon.pid) if name == "virtiofsd"]
    confinement_of("virtiofsd (the process serving the folder)", workers[-1])


def files_bench(output):
    return [line.split("\t") for line in output.splitlines() if "\t" in line]


def check_files(work, daemon):
    print("\nFile work in a shared folder (s in the VM / s on the host, host caches warm)")
    here = os.path.dirname(os.path.abspath(__file__))
    before = cpu_seconds(daemon.pid)
    wall = time.monotonic()
    code, out = guest("python3 /opt/files_bench.py /mnt/share")
    in_vm = files_bench(out)
    used, took = cpu_seconds(daemon.pid) - before, time.monotonic() - wall
    os.makedirs(f"{work}/hostbench", exist_ok=True)
    host = subprocess.run([sys.executable, f"{here}/guest/files_bench.py", f"{work}/hostbench"], capture_output=True, text=True)
    on_host = dict(files_bench(host.stdout))
    if code != 0 or not in_vm:
        report("files_bench.py in the VM", out[-70:])
    for name, seconds in in_vm:
        report(name, f"{float(seconds):.2f} / {float(on_host.get(name, 'nan')):.2f}")
    report("virtiofsd CPU (s) over the VM run's wall time (s)", f"{used:.2f} / {took:.1f}")


def check_hotplug(work, cache):
    print("\nAdding a folder to a running VM")
    second = virtiofsd(work, "share2", cache)
    with open(f"{work}/share2/hello", "w") as file:
        file.write("added while running\n")
    qmp = QMP(f"{work}/qmp.sock")
    started = time.monotonic()
    qmp.command("chardev-add", id="share2", backend={"type": "socket", "data": {"addr": {"type": "unix", "data": {"path": f"{work}/share2.sock"}}, "server": False}})  # fmt: skip
    reply = qmp.command("device_add", driver="vhost-user-fs-pci", chardev="share2", tag="share2", bus="port1", id="fs2")
    out = ""
    while time.monotonic() - started < 10:
        code, out = guest("mount -t virtiofs share2 /mnt/share2 2>&1 && cat /mnt/share2/hello")
        if code == 0:
            break
        time.sleep(0.05)
    report("device_add over QMP", "ok" if "return" in reply else json.dumps(reply)[:70])
    report("mounted and read in the VM", f"{out!r} after {time.monotonic() - started:.2f}s")
    guest("umount /mnt/share2")
    reply = qmp.command("device_del", id="fs2")
    time.sleep(0.5)
    code, out = guest("mount -t virtiofs share2 /mnt/share2 2>&1 | tail -1; echo code=$?")
    report("after device_del, mounting it again", out.replace("\n", " ")[:70])
    second.terminate()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", default="/var/tmp/mdt-vmspike")
    parser.add_argument("--net", choices=["vsock", "nic"], default="vsock")
    parser.add_argument("--cache", choices=["auto", "never", "always", "metadata"], default="auto")
    parser.add_argument("--confine", action="store_true")
    parser.add_argument("--mib", type=int, default=4096)
    parser.add_argument("--only", default="")
    options = parser.parse_args()
    work = options.work

    listen(socket.AF_VSOCK, (socket.VMADDR_CID_ANY, 5001), egress, only_cid=CID)
    listen(socket.AF_VSOCK, (socket.VMADDR_CID_ANY, 5053), dns, only_cid=CID)
    listen(socket.AF_VSOCK, (socket.VMADDR_CID_ANY, 6000), source_sink, only_cid=CID)
    listen(socket.AF_INET, ("127.0.0.1", SINK_PORT), source_sink)

    helpers = [virtiofsd(work, "share", options.cache)]
    if options.net == "nic":
        if os.path.exists(f"{work}/passt.sock"):
            os.remove(f"{work}/passt.sock")
        helpers.append(subprocess.Popen(["passt", "--foreground", "--socket", f"{work}/passt.sock"],
                                        stdout=open(f"{work}/passt.log", "w"), stderr=subprocess.STDOUT))  # fmt: skip
        time.sleep(0.3)

    print(f"net={options.net} cache={options.cache} confine={options.confine}")
    vm, seconds = boot(work, options.net, options.confine)
    try:
        report("QEMU start to the VM's agent answering over vsock (s)", f"{seconds:.2f}")
        _, out = guest("cat /tmp/insmod.log | head -3; uname -r")
        report("guest kernel", out.replace("\n", " | ")[:70])
        only = options.only.split(",") if options.only else []
        if not only or "confinement" in only:
            check_confinement(vm, helpers[0])
        if options.net == "vsock":
            if not only or "structure" in only:
                check_structure(work, options.confine)
            if not only or "egress" in only:
                check_egress()
        if not only or "throughput" in only:
            check_throughput(options.net, options.mib)
        if options.net == "vsock":
            if not only or "coherence" in only:
                check_coherence(work)
            if not only or "files" in only:
                check_files(work, helpers[0])
            if not only or "hotplug" in only:
                check_hotplug(work, options.cache)
    finally:
        try:
            conn = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            conn.settimeout(2)
            conn.connect((CID, 5000))
            conn.sendall(b"sync; poweroff -f\n")
            conn.close()
        except OSError:
            pass
        try:
            vm.wait(timeout=10)
        except subprocess.TimeoutExpired:
            vm.kill()
        for helper in helpers:
            helper.terminate()


if __name__ == "__main__":
    main()
