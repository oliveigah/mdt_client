"""The VM's whole network path when it has no network card.

TCP: nftables redirects every outgoing connection to port 15001. For each one
this opens a vsock stream to the host and sends `CONNECT ip:port`, the same
line msb sends MDT's egress proxy today, then copies bytes.

DNS: answers on 127.0.0.1:53 by passing each query to the host over vsock, so
the host sees every name looked up.

Nothing here is trusted: a root process in the VM can kill or replace it and
gains nothing, since vsock to the host is the only device that leads out.
"""
import socket
import struct
import threading

HOST = socket.VMADDR_CID_HOST
SO_ORIGINAL_DST = 80
CHUNK = 262_144


def pump(source, sink):
    buffer = bytearray(CHUNK)
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


def tunnel(client):
    raw = client.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
    port = struct.unpack_from("!H", raw, 2)[0]
    address = socket.inet_ntoa(raw[4:8])
    host = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    try:
        host.connect((HOST, 5001))
        host.sendall(f"CONNECT {address}:{port} HTTP/1.1\r\n\r\n".encode())
        head = b""
        while b"\r\n\r\n" not in head:
            data = host.recv(4096)
            if not data:
                raise OSError("closed")
            head += data
        if not head.startswith(b"HTTP/1.1 200"):
            raise OSError("refused")
        rest = head.split(b"\r\n\r\n", 1)[1]
        if rest:
            client.sendall(rest)
    except OSError:
        client.close()
        host.close()
        return
    up = threading.Thread(target=pump, args=(client, host), daemon=True)
    up.start()
    pump(host, client)
    up.join()
    client.close()
    host.close()


def tcp():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 15001))
    listener.listen(512)
    while True:
        client, _ = listener.accept()
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=tunnel, args=(client,), daemon=True).start()


def lookup(server, query, peer):
    try:
        with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as host:
            host.connect((HOST, 5053))
            host.sendall(struct.pack("!H", len(query)) + query)
            answer = b""
            while len(answer) < 2 or len(answer) < 2 + struct.unpack("!H", answer[:2])[0]:
                data = host.recv(65536)
                if not data:
                    return
                answer += data
        server.sendto(answer[2:], peer)
    except OSError:
        pass


def dns():
    server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    server.bind(("127.0.0.1", 53))
    while True:
        query, peer = server.recvfrom(65536)
        threading.Thread(target=lookup, args=(server, query, peer), daemon=True).start()


threading.Thread(target=dns, daemon=True).start()
tcp()
