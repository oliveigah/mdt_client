#!/usr/bin/env python3
"""Can msb run with no home folder and no network of its own?

Starts msb inside a bubble (bwrap) that has:
  - its own user, mount, network, IPC and UTS namespaces;
  - /usr read-only, msb's runtime, a throwaway MSB_HOME, one shared folder;
  - no /home, no /run, no network card: only loopback.

msb's two ways out are Unix sockets this script serves, standing in for MDT:
a CONNECT proxy and a DNS forwarder. `inside.py` joins them to the loopback
ports msb is told to use.

    python3 run.py [--work DIR] [--plain]

--plain runs the same VM with no bubble, for comparison. Needs an image
named `alpine` already pulled into DIR/home, and msb's runtime in
DIR/runtime (see the README lines printed on a missing piece).
"""
import argparse
import os
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = "confine-probe"
seen_connects = []
seen_names = []


def pipe(a, b):
    try:
        while True:
            data = a.recv(262144)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def proxy_one(client):
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = client.recv(4096)
        if not chunk:
            client.close()
            return
        head += chunk
    line = head.split(b"\r\n", 1)[0].decode("latin1")
    seen_connects.append(line)
    try:
        _, target, _ = line.split(" ")
        host, port = target.rsplit(":", 1)
        if port == "8099":
            return source(client)
        out = socket.create_connection((host.strip("[]"), int(port)), timeout=10)
    except (OSError, ValueError):
        client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        client.close()
        return
    out.settimeout(None)
    client.sendall(b"HTTP/1.1 200 OK\r\n\r\n")
    threading.Thread(target=pipe, args=(client, out), daemon=True).start()
    pipe(out, client)


def source(client):
    """Port 8099 anywhere is this: `GET /N` answers N MiB of zeros, so a
    download measures the path from here into the VM and nothing else."""
    client.sendall(b"HTTP/1.1 200 OK\r\n\r\n")
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = client.recv(4096)
        if not chunk:
            return client.close()
        head += chunk
    mib = int(head.split(b" ")[1].strip(b"/") or b"1")
    client.sendall(f"HTTP/1.0 200 OK\r\nContent-Length: {mib * 1024 * 1024}\r\n\r\n".encode())
    block = bytes(1024 * 1024)
    try:
        for _ in range(mib):
            client.sendall(block)
    except OSError:
        pass
    client.close()


def read_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise OSError("closed")
        data += chunk
    return data


def qname(packet):
    labels, at = [], 12
    while at < len(packet) and packet[at]:
        size = packet[at]
        labels.append(packet[at + 1 : at + 1 + size].decode("latin1"))
        at += 1 + size
    return ".".join(labels)


def resolver():
    with open("/etc/resolv.conf") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2 and parts[0] == "nameserver":
                return parts[1]
    return "127.0.0.53"


def dns_one(client):
    try:
        while True:
            (size,) = struct.unpack("!H", read_exact(client, 2))
            packet = read_exact(client, size)
            seen_names.append(qname(packet))
            out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            out.settimeout(5)
            out.sendto(packet, (resolver(), 53))
            reply, _ = out.recvfrom(4096)
            out.close()
            client.sendall(struct.pack("!H", len(reply)) + reply)
    except OSError:
        pass
    finally:
        client.close()


def serve(path, handler):
    if os.path.exists(path):
        os.unlink(path)
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(path)
    listener.listen(128)

    def loop():
        while True:
            client, _ = listener.accept()
            threading.Thread(target=handler, args=(client,), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()


def tcp_serve(port, path):
    """--plain only: the same proxy on a loopback port, as MDT has it today."""
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(128)

    def loop():
        while True:
            client, _ = listener.accept()
            threading.Thread(target=proxy_one, args=(client,), daemon=True).start()

    threading.Thread(target=loop, daemon=True).start()


def msb(env, *args, timeout=60):
    result = subprocess.run(
        [env["MSB_PATH"], *args], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout
    )
    return result.returncode, result.stdout.strip()


def guest(env, script, timeout=40):
    try:
        return msb(env, "exec", NAME, "--", "sh", "-c", script, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "timed out"


def vmm_pid():
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                words = [word.decode("latin1") for word in f.read().split(b"\0")]
        except OSError:
            continue
        if len(words) > 3 and words[1] == "machine" and NAME in words:
            return pid, " ".join(words[:4])
    return None


def status_lines(pid):
    wanted = ("Uid:", "Groups:", "NoNewPrivs:", "Seccomp:", "CapEff:")
    with open(f"/proc/{pid}/status") as f:
        return [line.strip().replace("\t", " ") for line in f if line.startswith(wanted)]


def report(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}" + (f": {detail}" if detail else ""), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", default="/var/tmp/mdt-msb-confine")
    parser.add_argument("--plain", action="store_true")
    parser.add_argument("--pid-namespace", action="store_true")
    parser.add_argument("--share-net", action="store_true", help="debug: keep the host's network in the bubble")
    parser.add_argument("--extra", default="", help="debug: more bwrap words, space separated")
    parser.add_argument("--hold", type=int, default=0, help="keep the VM this many seconds after the checks")
    args = parser.parse_args()

    work = args.work
    socks = os.path.join(work, "sock")
    share = os.path.join(work, "share")
    for folder in (socks, share, os.path.join(work, "fakehome"), os.path.join(work, "run")):
        os.makedirs(folder, exist_ok=True)
    for leftover in ("stop", "create.out", "inside.log"):
        if os.path.exists(os.path.join(socks, leftover)):
            os.unlink(os.path.join(socks, leftover))

    env = {
        "PATH": "/usr/bin:/usr/sbin",
        "HOME": os.path.join(work, "fakehome"),
        "XDG_RUNTIME_DIR": os.path.join(work, "run"),
        "MSB_HOME": os.path.join(work, "home"),
        "MSB_PATH": os.path.join(work, "runtime/bin/msb"),
        "MSB_BACKEND": "local",
        "NO_COLOR": "1",
    }
    if not os.path.exists(env["MSB_PATH"]):
        sys.exit(f"copy MDT's priv/microsandbox to {work}/runtime first")

    serve(os.path.join(socks, "proxy.sock"), proxy_one)
    serve(os.path.join(socks, "dns.sock"), dns_one)
    with open(os.path.join(share, "from-host.txt"), "w") as f:
        f.write("written on the host\n")

    msb(env, "rm", "--force", NAME)

    create = [
        env["MSB_PATH"], "create", "alpine", "--name", NAME, "--replace", "--pull", "never",
        "--cpus", "2", "--memory", "1G",
        "--proxy", "http://127.0.0.1:18999", "--net", "public,private",
        "--volume", f"{share}:/share",
    ]  # fmt: skip

    started = time.monotonic()
    if args.plain:
        tcp_serve(18999, None)
        code, out = msb(env, *create[1:], timeout=120)
        bubble = None
        print(f"plain msb create: exit {code} in {time.monotonic() - started:.1f} s\n{out}")
    else:
        create += ["--dns-nameserver", "127.0.0.1:5353"]
        bwrap = [
            "bwrap",
            "--unshare-user", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup",
            # Root inside the bubble only, with two capabilities inside.py uses
            # once (a dead-end default route) and drops before msb starts.
            "--uid", "0", "--gid", "0", "--cap-add", "CAP_NET_ADMIN", "--cap-add", "CAP_SETPCAP",
            *([] if args.share_net else ["--unshare-net"]),
            *args.extra.split(),
            *(["--unshare-pid"] if args.pid_namespace else []),
            "--die-with-parent",
            "--ro-bind", "/usr", "/usr",
            "--symlink", "usr/bin", "/bin", "--symlink", "usr/sbin", "/sbin",
            "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
            "--proc", "/proc", "--dev", "/dev", "--dev-bind", "/dev/kvm", "/dev/kvm",
            "--tmpfs", "/tmp", "--tmpfs", "/run",
            "--bind", work, work,
            "--chdir", work,
            "--clearenv",
            *[item for key, value in env.items() for item in ("--setenv", key, value)],
            "--", "python3", os.path.join(HERE, "inside.py"), socks, *create,
        ]  # fmt: skip
        # inside.py must be readable in the bubble: it is, under `work`, once copied.
        shutil.copy(os.path.join(HERE, "inside.py"), os.path.join(work, "inside.py"))
        bwrap[bwrap.index(os.path.join(HERE, "inside.py"))] = os.path.join(work, "inside.py")
        bubble = subprocess.Popen(bwrap)
        deadline = time.monotonic() + 120
        while not os.path.exists(os.path.join(socks, "create.out")) and time.monotonic() < deadline:
            if bubble.poll() is not None:
                break
            time.sleep(0.1)
        try:
            with open(os.path.join(socks, "create.out")) as f:
                print(f"msb create in the bubble, {time.monotonic() - started:.1f} s: {f.read().strip()}")
        except OSError:
            print(f"the bubble ended early, exit {bubble.poll()}")
            return

    try:
        checks(env, share, bubble)
        time.sleep(args.hold)
    finally:
        msb(env, "stop", NAME)
        msb(env, "rm", "--force", NAME)
        with open(os.path.join(socks, "stop"), "w"):
            pass
        if bubble:
            try:
                bubble.wait(timeout=10)
            except subprocess.TimeoutExpired:
                bubble.kill()


def only_store(pid, store):
    """Under /home, the bubble holds the folders that lead to msb's store and
    nothing else. msb's store keeps its own path in the bubble, so when it is
    under your home folder that one path is there."""
    root = f"/proc/{pid}/root"
    if not os.path.exists(root + "/home"):
        return True, "no /home at all"
    if not store.startswith("/home/"):
        return False, "a /home, and the store isn't under it"
    path = "/home"
    for part in store[len("/home/"):].split("/"):
        entries = os.listdir(root + path)
        if entries != [part]:
            return False, f"{path} holds {entries}"
        path += "/" + part
    return True, f"only {store}"


def checks(env, share, bubble):
    print("\nThe VM, driven from outside the bubble (msb exec):")
    code, out = guest(env, "uname -r; ip -o link | cut -d: -f2 | tr -d ' ' | tr '\\n' ' '")
    report("exec from the host reaches the VM", code == 0, out.replace("\n", " | "))
    if code != 0:
        return

    code, out = guest(env, "cat /share/from-host.txt && echo from-vm > /share/from-vm.txt && echo wrote")
    host_sees = os.path.exists(os.path.join(share, "from-vm.txt"))
    report("shared folder both ways", code == 0 and host_sees, out.replace("\n", " | "))

    before = len(seen_connects)
    code, out = guest(env, "wget -q -T 15 -O - http://example.com/ | head -c 60")
    report("HTTP through the socket", code == 0 and "<" in out, f"{out[:60]!r}; host saw {seen_connects[before:]}")

    before = len(seen_connects)
    code, out = guest(env, "wget -q -T 15 -O - https://example.com/ | head -c 60")
    report("HTTPS through the socket", code == 0 and "<" in out, f"host saw {seen_connects[before:]}")

    before = len(seen_names)
    code, out = guest(env, "nslookup -type=a probe-name.example.org 2>&1 | tail -3")
    report("DNS names seen by the host", "probe-name.example.org" in seen_names[before:], f"{sorted(set(seen_names[before:]))}")

    before = len(seen_names)
    code, out = guest(env, "nslookup -type=a other-name.example.org 8.8.8.8 2>&1 | tail -3")
    answered = code == 0 and "timed out" not in out and "can't" not in out
    names = sorted(set(seen_names[before:]))
    report("DNS aimed at 8.8.8.8 doesn't go around the host", names != [] or not answered, f"host saw {names}; the VM got {out.splitlines()[-1] if out else 'nothing'!r}")

    code, out = guest(env, "cat /etc/resolv.conf | tr '\\n' ' '; wget -q -T 10 -O - http://172.66.147.243/ 2>&1 | head -c 40")
    print(f"  note  resolv.conf and HTTP by address: {out!r}; host saw {seen_connects[-1:]}")
    try:
        with open(os.path.join(os.path.dirname(share), "sock/inside.log")) as f:
            print("  note  relay in the bubble: " + " | ".join(f.read().split("\n")[:12]))
    except OSError:
        print("  note  relay in the bubble logged nothing")
    code, out = msb(env, "logs", NAME, "--tail", "15")
    print("  note  msb logs: " + out[-900:].replace("\n", " | "))

    print("\nThe VM process, read from /proc on the host:")
    found = vmm_pid()
    if not found:
        report("found the VM process", False)
        return
    pid, words = found
    print(f"  pid {pid}: {words}")
    for line in status_lines(pid):
        print(f"    {line}")
    mine = {ns: os.readlink(f"/proc/self/ns/{ns}") for ns in ("user", "mnt", "net", "ipc", "uts", "pid", "cgroup")}
    theirs = {ns: os.readlink(f"/proc/{pid}/ns/{ns}") for ns in mine}
    own = [ns for ns in mine if mine[ns] != theirs[ns]]
    print(f"    own namespaces: {' '.join(own) or 'none'}")
    try:
        root = sorted(os.listdir(f"/proc/{pid}/root"))
        print(f"    its / holds: {' '.join(root)}")
        ok, what = only_store(pid, env["MSB_HOME"])
        report("nothing of /home in its view but msb's own store", ok, what)
        report("no /run/user, no docker socket", not os.path.exists(f"/proc/{pid}/root/run/docker.sock") and not os.path.exists(f"/proc/{pid}/root/run/user"))
    except OSError as error:
        print(f"    its / could not be read: {error}")
    try:
        with open(f"/proc/{pid}/net/dev") as f:
            cards = [line.split(":")[0].strip() for line in f.readlines()[2:]]
        report("its network cards", cards == ["lo"], " ".join(cards))
    except OSError as error:
        print(f"    its network could not be read: {error}")
    sockets = subprocess.run(["ss", "-Htnp"], stdout=subprocess.PIPE, text=True).stdout
    report("no TCP socket of its own in the host's network", f"pid={pid}," not in sockets)

    if bubble:
        print("\nWith the way out closed (proxy socket removed):")
        os.rename(os.path.join(os.path.dirname(share), "sock/proxy.sock"), os.path.join(os.path.dirname(share), "sock/proxy.off"))
        code, out = guest(env, "wget -q -T 8 -O - http://example.com/ 2>&1 | head -c 80; echo; echo done")
        report("no MDT, no internet", "<" not in out, out.replace("\n", " | ")[:90])
        os.rename(os.path.join(os.path.dirname(share), "sock/proxy.off"), os.path.join(os.path.dirname(share), "sock/proxy.sock"))


if __name__ == "__main__":
    main()
