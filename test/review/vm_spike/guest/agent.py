"""Runs commands for the host. Listens on vsock port 5000: the host connects
in, which msb's --vsock cannot do (it only goes from the VM to the host)."""
import socket
import subprocess
import threading


def serve(conn):
    with conn:
        line = b""
        while not line.endswith(b"\n"):
            data = conn.recv(65536)
            if not data:
                return
            line += data
        done = subprocess.run(line.decode(), shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        conn.sendall(done.stdout + b"\n__EXIT__ %d\n" % done.returncode)


listener = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
listener.bind((socket.VMADDR_CID_ANY, 5000))
listener.listen(16)
while True:
    conn, _ = listener.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
