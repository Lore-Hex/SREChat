#!/usr/bin/env python3
"""Dumb TCP forwarder. One process per replication link; killing it IS the
network partition, restarting it is the heal. No root, no firewall rules."""

import socket
import sys
import threading


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (src, dst):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def main(listen_port, target_port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", listen_port))
    server.listen(64)
    while True:
        client, _addr = server.accept()
        try:
            upstream = socket.create_connection(("127.0.0.1", target_port), timeout=3)
        except OSError:
            client.close()
            continue
        threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
        threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


if __name__ == "__main__":
    main(int(sys.argv[1]), int(sys.argv[2]))
