#!/usr/bin/env python3
"""Runs inside the bubble, beside msb. The bubble has its own network with
only loopback, so this is msb's whole way out: it joins two loopback ports
to two Unix sockets the host put in the bubble.

    127.0.0.1:18999 (TCP)       -> proxy.sock   msb's --proxy
    127.0.0.1:5353  (UDP, TCP)  -> dns.sock     msb's --dns-nameserver

Then it runs the command it was given (msb create ...), and stays until a
file named `stop` appears in the socket folder.
"""
import os
import socket
import struct
import subprocess
import sys
import threading
import time

SOCKS = sys.argv[1]
COMMAND = sys.argv[2:]


def log(text):
    with open(os.path.join(SOCKS, "inside.log"), "a") as f:
        f.write(text + "\n")


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


def join(client, path):
    out = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        out.connect(path)
    except OSError:
        client.close()
        return
    threading.Thread(target=pipe, args=(client, out), daemon=True).start()
    pipe(out, client)
    client.close()
    out.close()


def tcp(port, path):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(128)
    while True:
        client, _ = listener.accept()
        log(f"tcp {port} accepted")
        threading.Thread(target=join, args=(client, path), daemon=True).start()


def read_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise OSError("closed")
        data += chunk
    return data


def udp_one(server, packet, sender, path):
    try:
        out = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        out.settimeout(5)
        out.connect(path)
        out.sendall(struct.pack("!H", len(packet)) + packet)
        (size,) = struct.unpack("!H", read_exact(out, 2))
        server.sendto(read_exact(out, size), sender)
        out.close()
        log(f"dns udp {len(packet)} bytes answered")
    except OSError as error:
        log(f"dns udp failed: {error}")


def udp(port, path):
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("127.0.0.1", port))
    while True:
        packet, sender = server.recvfrom(4096)
        threading.Thread(target=udp_one, args=(server, packet, sender, path), daemon=True).start()


proxy = os.path.join(SOCKS, "proxy.sock")
dns = os.path.join(SOCKS, "dns.sock")
threading.Thread(target=tcp, args=(18999, proxy), daemon=True).start()
threading.Thread(target=tcp, args=(5353, dns), daemon=True).start()
threading.Thread(target=udp, args=(5353, dns), daemon=True).start()
time.sleep(0.2)

# msb gives the VM an IPv4 address only when the kernel can pick a route to a
# public address (host_has_ipv4_route, network.rs:804). This network has none,
# so add a default route into loopback: it leads nowhere. Then msb starts with
# every capability dropped for good, so it cannot change the route.
route = subprocess.run(["ip", "route", "add", "default", "dev", "lo"], capture_output=True, text=True)
log(f"default route into loopback: exit {route.returncode} {route.stderr.strip()}")
drop = ["setpriv", "--bounding-set=-all", "--inh-caps=-all", "--"]
result = subprocess.run(drop + COMMAND, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
with open(os.path.join(SOCKS, "create.out"), "w") as f:
    f.write(f"exit {result.returncode}\n{result.stdout}")

while not os.path.exists(os.path.join(SOCKS, "stop")):
    time.sleep(0.2)
