#!/usr/bin/env python3
"""msb in the bubble with the real relay (native/mdt_relay) as its first
process, started and stopped the way MDT will do it: detached, `start.out`
for how the start went, `control.sock` for status and stop.

    python3 relay_live.py [--work DIR]

DIR needs runtime/bin/msb, runtime/bin/mdt-relay and an `alpine` image in
DIR/home. This script stands in for MDT: a CONNECT proxy and a DNS forwarder
on two Unix sockets (the ones run.py has).
"""
import argparse
import os
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run as base  # noqa: E402

NAME = base.NAME
# Another bwrap than the system's, for a distribution whose AppArmor profile
# is attached by path.
BWRAP = os.environ.get("MDT_BWRAP", "bwrap")
MIB = 1024 * 1024


def bubble_words(work, env, msb_words):
    """Everything the VM is made of sits under /mdt, a path that exists only
    in the bubble: msb outside it cannot boot this VM, since its disks and
    folders aren't there. Only msb's home keeps its own path, so `msb exec`
    from the host finds the VM's sockets."""
    inside = {**env, "MSB_PATH": "/mdt/runtime/bin/msb"}
    return [
        BWRAP,
        "--unshare-user", "--unshare-pid", "--unshare-net", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup",
        "--as-pid-1",
        "--uid", "0", "--gid", "0", "--cap-add", "CAP_NET_ADMIN", "--cap-add", "CAP_SETPCAP",
        "--ro-bind", "/usr", "/usr",
        "--symlink", "usr/bin", "/bin", "--symlink", "usr/sbin", "/sbin",
        "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
        "--proc", "/proc", "--dev", "/dev", "--dev-bind", "/dev/kvm", "/dev/kvm",
        "--tmpfs", "/tmp", "--tmpfs", "/run",
        "--ro-bind", os.path.join(work, "runtime"), "/mdt/runtime",
        "--bind", os.path.join(work, "sock"), "/mdt/sockets",
        "--bind", os.path.join(work, "disks"), "/mdt/disks",
        "--bind", os.path.join(work, "share"), "/mdt/shares/0",
        "--bind", env["MSB_HOME"], env["MSB_HOME"],
        "--chdir", "/",
        "--clearenv",
        *[item for key, value in inside.items() for item in ("--setenv", key, value)],
        "--",
        "/mdt/runtime/bin/mdt-relay", "--sockets", "/mdt/sockets", "--name", NAME, "--",
        "/mdt/runtime/bin/msb", *msb_words,
    ]  # fmt: skip


def start(work, env, msb_words, wait=120):
    """Detached, as MDT starts it: nothing ties the bubble to this process."""
    socks = os.path.join(work, "sock")
    for leftover in ("start.out", "bubble.pid"):
        path = os.path.join(socks, leftover)
        if os.path.exists(path):
            os.unlink(path)

    log = os.path.join(socks, "bubble.log")
    launcher = 'echo $$ > "$PIDFILE"; exec "$@"'
    subprocess.run(
        ["setsid", "--fork", "sh", "-c", launcher, "mdt-bubble", *bubble_words(work, env, msb_words)],
        env={**os.environ, "PIDFILE": os.path.join(socks, "bubble.pid")},
        stdin=subprocess.DEVNULL, stdout=open(log, "w"), stderr=subprocess.STDOUT, check=True,
    )  # fmt: skip

    started = time.monotonic()
    deadline = started + wait
    while time.monotonic() < deadline:
        try:
            with open(os.path.join(socks, "start.out")) as f:
                status, _, output = f.read().partition("\n")
            return int(status), output.strip(), time.monotonic() - started
        except OSError:
            pass
        try:
            with open(os.path.join(socks, "bubble.pid")) as f:
                pid = int(f.read())
            if not os.path.exists(f"/proc/{pid}"):
                with open(log) as f:
                    return -1, "the bubble ended: " + f.read().strip(), time.monotonic() - started
        except (OSError, ValueError):
            pass
        time.sleep(0.05)
    return -1, "no start.out in time", wait


def control(work, word, wait=120):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(wait)
            s.connect(os.path.join(work, "sock/control.sock"))
            s.sendall(word.encode() + b"\n")
            data = b""
            while chunk := s.recv(4096):
                data += chunk
            return data.decode().strip()
    except OSError as error:
        return f"down ({error.__class__.__name__})"


def bubble_pid(work):
    try:
        with open(os.path.join(work, "sock/bubble.pid")) as f:
            pid = int(f.read())
        return pid if os.path.exists(f"/proc/{pid}") else None
    except (OSError, ValueError):
        return None


def gone(work, wait=10):
    """No relay, no VM process, and nothing answering the control socket."""
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if relay_pid() is None and base.vmm_pid() is None and control(work, "status", 2).startswith("down"):
            return True
        time.sleep(0.1)
    return False


def relay_pid():
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                words = f.read().split(b"\0")
        except OSError:
            continue
        if words and words[0].endswith(b"/mdt-relay") and NAME.encode() in words:
            return pid
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--work", default="/var/tmp/mdt-msb-confine")
    parser.add_argument("--mib", type=int, default=1024)
    args = parser.parse_args()
    work = args.work
    socks, share, disks = (os.path.join(work, name) for name in ("sock", "share", "disks"))
    for folder in (socks, share, disks):
        os.makedirs(folder, exist_ok=True)

    env = {
        "PATH": "/usr/bin:/usr/sbin",
        "HOME": os.path.join(work, "home"),
        "MSB_HOME": os.path.join(work, "home"),
        "MSB_PATH": os.path.join(work, "runtime/bin/msb"),
        "MSB_BACKEND": "local",
        "NO_COLOR": "1",
    }

    base.serve(os.path.join(socks, "proxy.sock"), base.proxy_one)
    base.serve(os.path.join(socks, "dns.sock"), base.dns_one)
    with open(os.path.join(share, "from-host.txt"), "w") as f:
        f.write("written on the host\n")

    disk = os.path.join(disks, "work.img")
    if os.path.exists(disk):
        os.unlink(disk)
    subprocess.run(["truncate", "-s", "8G", disk], check=True)
    subprocess.run(["mkfs.ext4", "-q", "-F", "-E", "root_owner=0:0", disk], check=True)

    create = [
        "create", "alpine", "--name", NAME, "--replace", "--pull", "never",
        "--cpus", "2", "--memory", "1G",
        "--proxy", "http://127.0.0.1:3128", "--dns-nameserver", "127.0.0.1:5353",
        "--net", "public,private",
        "--mount-disk", "/mdt/disks/work.img:/work",
        "--volume", "/mdt/shares/0:/share",
    ]  # fmt: skip

    try:
        print("1. Created in the bubble by the relay")
        status, output, took = start(work, env, create)
        base.report("msb create", status == 0, f"exit {status} in {took:.1f} s {output[-200:]}")
        if status != 0:
            return
        base.report("control.sock says", control(work, "status") == "running", control(work, "status"))

        base.checks(env, share, True)

        print("\nThe relay itself, read from /proc on the host:")
        pid = relay_pid()
        for line in base.status_lines(pid):
            print(f"    {line}")
        caps = {line.split(":")[0]: line.split()[-1] for line in open(f"/proc/{pid}/status") if line.startswith("Cap")}
        base.report("no capability left, none to regain", int(caps["CapEff"], 16) == 0 and int(caps["CapBnd"], 16) == 0)

        print("\nA second relay for the same VM")
        status, output, took = start(work, env, ["start", NAME], wait=15)
        base.report("refuses to start", status != 0 and "already running" in output, output[-120:])
        base.report("the first one still answers", control(work, "status") == "running", control(work, "status"))

        print(f"\n2. {args.mib} MiB from the host side into the VM, through msb, the relay and the socket")
        code, out = base.guest(env, f"a=$(cut -d' ' -f1 /proc/uptime); wget -q -O /dev/null http://9.9.9.9:8099/{args.mib}; b=$(cut -d' ' -f1 /proc/uptime); echo \"$a $b\"", timeout=300)
        try:
            a, b = (float(x) for x in out.split()[-2:])
            base.report("download", code == 0, f"{args.mib / (b - a):.0f} MiB/s ({b - a:.1f} s)")
        except ValueError:
            base.report("download", False, out[-200:])

        print("\n3. Stopped through control.sock, started again in a new bubble")
        base.guest(env, "echo kept-across-stop > /work/marker")
        answer = control(work, "stop")
        base.report("stop answered", answer.startswith("stopped"), answer.replace("\n", " | ")[:80])
        base.report("the bubble and the VM's process are gone", gone(work))
        base.report("control.sock is", control(work, "status").startswith("down"), control(work, "status"))

        code, out = base.msb(env, "start", NAME)
        base.report("msb outside the bubble cannot boot it", code != 0 and base.vmm_pid() is None, out.replace("\n", " ")[-150:])
        code, out = base.guest(env, "echo booted")
        base.report("nor can msb exec, which boots a stopped VM by itself", "booted" not in out and base.vmm_pid() is None, out.replace("\n", " ")[-150:])

        status, output, took = start(work, env, ["start", NAME])
        base.report("msb start in a new bubble", status == 0, f"exit {status} in {took:.1f} s {output[-200:]}")
        code, out = base.guest(env, "cat /work/marker; ip -o -4 addr show eth0 | wc -l")
        base.report("the disk kept its file; the VM has its address", "kept-across-stop" in out and out.strip().endswith("1"), out.replace("\n", " | "))

        print("\n4. The relay is killed outright, like a crash: the bubble's processes end with it")
        base.guest(env, "echo before-the-kill > /work/marker2; sync")
        os.kill(int(relay_pid()), signal.SIGKILL)
        base.report("the VM's process went with it", gone(work))
        status, output, took = start(work, env, ["start", NAME])
        base.report("msb start after that", status == 0, f"exit {status} in {took:.1f} s {output[-300:]}")
        if status != 0:
            status, output, took = start(work, env, create)
            base.report("msb create --replace instead", status == 0, f"exit {status} in {took:.1f} s {output[-200:]}")
        code, out = base.guest(env, "cat /work/marker2")
        base.report("the synced file survived", "before-the-kill" in out, out.strip())

        print("\n5. Recreated")
        control(work, "stop")
        gone(work)
        status, output, took = start(work, env, create)
        code, out = base.guest(env, "cat /work/marker /work/marker2 | tr '\\n' ' '")
        base.report("create --replace keeps the disk", status == 0 and "kept-across-stop" in out, out.strip())
    finally:
        control(work, "stop", wait=100)
        gone(work)
        pid = relay_pid()
        if pid:
            os.kill(int(pid), signal.SIGKILL)
            gone(work)
        subprocess.run(
            [BWRAP, "--unshare-user", "--unshare-pid", "--unshare-net", "--ro-bind", "/usr", "/usr",
             "--symlink", "usr/bin", "/bin", "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
             "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp", "--bind", work, work, "--clearenv",
             *[item for key, value in env.items() for item in ("--setenv", key, value)],
             "--", env["MSB_PATH"], "rm", "--force", NAME],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )  # fmt: skip


if __name__ == "__main__":
    main()
