"""Moves MiB megabytes between the VM and the host's source/sink and prints
`seconds MiB/s`. usage: bench.py vsock|tcp down|up HOST PORT MIB"""
import socket
import struct
import sys
import time

kind, direction, host, port, mib = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
size = mib * 1024 * 1024
if kind == "vsock":
    conn = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    conn.connect((int(host), port))
else:
    conn = socket.create_connection((host, port))
started = time.monotonic()
if direction == "down":
    conn.sendall(b"D" + struct.pack("!Q", size))
    buffer = bytearray(1024 * 1024)
    got = 0
    while True:
        count = conn.recv_into(buffer)
        if not count:
            break
        got += count
    assert got == size, (got, size)
else:
    conn.sendall(b"U" + struct.pack("!Q", size))
    chunk = bytes(1024 * 1024)
    for _ in range(mib):
        conn.sendall(chunk)
    conn.shutdown(socket.SHUT_WR)
    assert conn.recv(1) == b"k"
seconds = time.monotonic() - started
print(f"{seconds:.3f} {mib / seconds:.0f}")
