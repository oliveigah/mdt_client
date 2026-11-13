"""Sends a DNS query straight to 1.1.1.1 over UDP, around the VM's resolver."""
import socket

query = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01"
conn = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
conn.settimeout(2)
try:
    conn.sendto(query, ("1.1.1.1", 53))
    conn.recv(512)
    print("answered")
except OSError as error:
    print(f"no answer ({error})")
