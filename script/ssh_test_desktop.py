"""Independent SSH peer for the synthetic RFB chart, bound to loopback."""

import argparse
import base64
import hashlib
import json
import socket
from pathlib import Path

import paramiko
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519, ec
from test_desktop import record, serve


class ChartLogin(paramiko.ServerInterface):
    def __init__(self, expected_public, log):
        self.expected_public = expected_public
        self.log = log

    def get_allowed_auths(self, username):
        return "publickey" if username == "fixture-key" else "password"

    def check_auth_password(self, username, password):
        if username == "fixture" and password == "chart-test-only":
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        if username == "fixture-key" and key.get_base64() == self.expected_public:
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        if destination in (("127.0.0.1", 5900), ("chart.fixture.invalid", 5917)):
            record(self.log, "desktopRequested", host=destination[0], port=destination[1])
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ready", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    options = parser.parse_args()
    host_key = paramiko.ECDSAKey.generate(bits=256)
    # These identities exist for one run. Only the test peer accepts the
    # generated Ed25519 public key. No user identity is read by the fixture.
    identities = [ed25519.Ed25519PrivateKey.generate()] + [
        ec.generate_private_key(curve) for curve in (ec.SECP256R1(), ec.SECP384R1(), ec.SECP521R1())
    ]
    fixtures = []
    for key in identities:
        encoded = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH,
                                    serialization.BestAvailableEncryption(b"chart-key-phrase"))
        public = key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH)
        fixtures.append({"key": encoded.decode(), "public": public.decode()})
    options.ready.with_name("test-keys.json").write_text(json.dumps(fixtures))
    expected_public = fixtures[0]["public"].split()[1]
    fingerprint = base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode().rstrip("=")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener, options.log.open("w") as log:
        listener.bind(("127.0.0.1", 0))
        listener.listen(2)
        options.ready.write_text(json.dumps({"port": listener.getsockname()[1], "pin": "SHA256:" + fingerprint}))
        while True:
            connection, _ = listener.accept()
            with connection, paramiko.Transport(connection) as transport:
                try:
                    transport.add_server_key(host_key)
                    transport.start_server(server=ChartLogin(expected_public, log))
                    channel = transport.accept(timeout=15)
                    if channel:
                        record(log, "authenticatedChart")
                        serve(channel, log)
                except EOFError:
                    record(log, "closed")
                except (OSError, ValueError, paramiko.SSHException) as error:
                    record(log, "ended", kindName=type(error).__name__)


if __name__ == "__main__":
    main()
