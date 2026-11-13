"""Endpoints for the tunnel benchmark, outside the BEAM so its CPU time is the relay's alone.

serve PORT           on each connection: read a line "SEND <n>" or "FIRST <n>", then send n zero bytes.
                     "FIRST" mode is not used over the wire: see serve_first.
serve_first PORT     speaks first: sends "220 hello\\r\\n" as soon as a client connects, then closes.
fetch PORT N [CONNECT_TARGET]
                     connect to PORT; with CONNECT_TARGET, open a tunnel through an HTTP CONNECT proxy
                     first. Ask for N bytes, read them, print seconds and bytes.
banner PORT [CONNECT_TARGET]
                     connect, send nothing, print seconds until the first byte arrives.
"""

import socket
import sys
import threading
import time

CHUNK = bytes(1 << 20)


def serve(port, first):
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(64)
    print("ready", flush=True)

    def handle(conn):
        try:
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            if first:
                conn.sendall(b"220 hello\r\n")
                return
            line = b""
            while not line.endswith(b"\n"):
                data = conn.recv(64)
                if not data:
                    return
                line += data
            left = int(line.split()[1])
            while left > 0:
                sent = conn.send(CHUNK[: min(left, len(CHUNK))])
                left -= sent
        except OSError:
            pass
        finally:
            conn.close()

    while True:
        conn, _ = listener.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


def open_tunnel(port, target):
    conn = socket.create_connection(("127.0.0.1", port))
    conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    if target:
        conn.sendall(f"CONNECT {target} HTTP/1.1\r\n\r\n".encode())
        reply = b""
        while b"\r\n\r\n" not in reply:
            data = conn.recv(4096)
            if not data:
                raise SystemExit(f"proxy closed: {reply!r}")
            reply += data
        if not reply.startswith(b"HTTP/1.1 200"):
            raise SystemExit(f"proxy refused: {reply!r}")
    return conn


def fetch(port, count, target):
    conn = open_tunnel(port, target)
    started = time.perf_counter()
    conn.sendall(f"SEND {count}\n".encode())
    got = 0
    view = memoryview(bytearray(1 << 20))
    while got < count:
        n = conn.recv_into(view)
        if n == 0:
            break
        got += n
    print(f"{time.perf_counter() - started:.4f} {got}")


def banner(port, target):
    started = time.perf_counter()
    conn = open_tunnel(port, target)
    conn.recv(64)
    print(f"{time.perf_counter() - started:.4f}")


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "serve":
        serve(int(sys.argv[2]), False)
    elif mode == "serve_first":
        serve(int(sys.argv[2]), True)
    elif mode == "fetch":
        fetch(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4] if len(sys.argv) > 4 else None)
    elif mode == "banner":
        banner(int(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else None)
