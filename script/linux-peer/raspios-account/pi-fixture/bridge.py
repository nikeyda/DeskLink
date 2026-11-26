#!/usr/bin/python3
"""Relay the guest socket only to the loopback screen-sharing server."""
import select
import socket
import threading


def relay(peer):
    with peer:
        try:
            with socket.create_connection(("127.0.0.1", 5903), timeout=5) as service:
                service.settimeout(None)
                while True:
                    readable, _, _ = select.select((peer, service), (), ())
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        destination = service if source is peer else peer
                        destination.sendall(data)
        except OSError:
            return


with socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM) as listener:
    listener.bind((socket.VMADDR_CID_ANY, 5903))
    listener.listen()
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=relay, args=(connection,), daemon=True).start()
