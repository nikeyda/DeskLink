"""Test chart and receipts on loopback or a specified paired device tunnel."""

import argparse
import json
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import uuid4

from test_desktop import serve


def accept_display(listener, apple, receipt, lock, allowed_peer):
    def received(event, fields):
        with lock:
            if event == "frame":
                receipt["frames"] += 1
            elif event == "fixtureKey":
                key = fields["keysym"]
                receipt["keys"].append(key if fields["down"] else -key)
            elif event == "pointer":
                receipt["pointers"].append([fields["buttons"], fields["x"], fields["y"]])

    try:
        with listener:
            listener.settimeout(30)
            client, address = listener.accept()
            if address[0] != allowed_peer:
                client.close()
                raise ValueError("Unexpected test client")
        serve(client, received, include_clipboard=False, size=(320, 192) if apple else (160, 96),
              apple_server=apple, capture_test_keys=True)
    except EOFError:
        pass
    except (OSError, ValueError) as error:
        with lock:
            receipt["error"] = str(error)
    finally:
        with lock:
            receipt["closed"] = True


class Control(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path not in ("/apple", "/standard"):
            return self.send_error(404)
        listener = socket.socket(self.server.address_family, socket.SOCK_STREAM)
        listener.bind((self.server.server_address[0], 0))
        listener.listen(1)
        case = str(uuid4())
        receipt = dict(frames=0, closed=False, keys=[], pointers=[])
        self.server.receipts[case] = receipt
        port = listener.getsockname()[1]
        threading.Thread(target=accept_display, args=(listener, self.path == "/apple", receipt, self.server.lock, self.server.allowed_peer),
                         daemon=True).start()
        self.reply(dict(id=case, port=port))

    def do_GET(self):
        with self.server.lock:
            result = self.server.receipts.get(self.path.removeprefix("/"))
            if result is None:
                return self.send_error(404)
            self.reply(result)

    def reply(self, result):
        body = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ReceiptServer(ThreadingHTTPServer):
    def __init__(self, host, peer):
        self.allowed_peer = peer
        self.address_family = socket.AF_INET6 if ":" in host else socket.AF_INET
        self.receipts = {}
        self.lock = threading.Lock()
        super().__init__((host, 0), Control)

    def verify_request(self, request, client_address):
        return client_address[0] == self.allowed_peer


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", help="Paired iPad identifier from devicectl")
    device = parser.parse_args().device
    host = peer = "127.0.0.1"
    if device:
        sys.path.insert(0, str(Path(__file__).resolve().parent / "linux-peer"))
        from paired_device import tunnel_addresses
        host, peer = tunnel_addresses(device)
    with ReceiptServer(host, peer) as server:
        print(server.server_port, flush=True)
        server.serve_forever()
