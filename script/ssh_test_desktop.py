"""Independent SSH peer for the synthetic RFB chart, bound to loopback."""

import argparse
import base64
import hashlib
import json
import os
import socket
from pathlib import Path

import paramiko
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, ed25519, rsa
from test_desktop import record, serve


class ChartLogin(paramiko.ServerInterface):
    def __init__(self, authorized_keys, log):
        self.authorized_keys = authorized_keys
        self.log = log

    def get_allowed_auths(self, username):
        return "publickey" if username in self.authorized_keys else "password"

    def check_auth_password(self, username, password):
        if username == "fixture" and password == "chart-test-only":
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        if self.authorized_keys.get(username) == key.get_base64():
            record(self.log, "offeredAuthorizedKey", keyType=key.get_name())
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
    host_algorithm = os.environ.get("DESKLINK_FIXTURE_HOST_ALGORITHM", "ecdsa-sha2-nistp256")
    rsa_algorithms = {"rsa-sha2-256", "rsa-sha2-512"}
    if host_algorithm in rsa_algorithms:
        host_key = paramiko.RSAKey.generate(bits=2048)
    elif host_algorithm == "ecdsa-sha2-nistp256":
        host_key = paramiko.ECDSAKey.generate(bits=256)
    else:
        raise ValueError("Expected an ECDSA or RSA SHA-2 host algorithm")
    # These identities exist for one run and are accepted only by the test peer.
    identities = [ed25519.Ed25519PrivateKey.generate()] + [
        ec.generate_private_key(curve) for curve in (ec.SECP256R1(), ec.SECP384R1(), ec.SECP521R1())
    ] + [rsa.generate_private_key(public_exponent=65537, key_size=2048)]
    fixtures = []
    for key in identities:
        encoded = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH,
                                    serialization.BestAvailableEncryption(b"chart-key-phrase"))
        public = key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH)
        fixture = {"key": encoded.decode(), "public": public.decode()}
        if isinstance(key, rsa.RSAPrivateKey):
            fixture["pem"] = [
                key.private_bytes(serialization.Encoding.PEM, format, serialization.NoEncryption()).decode()
                for format in (serialization.PrivateFormat.TraditionalOpenSSL, serialization.PrivateFormat.PKCS8)
            ]
        fixtures.append(fixture)
    with options.ready.with_name("test-keys.json").open("w") as file:
        json.dump(fixtures, file)
    authorized_keys = {
        "fixture-key": fixtures[0]["public"].split()[1],
        "fixture-rsa": fixtures[-1]["public"].split()[1],
    }
    rsa_preference = os.environ.get("DESKLINK_FIXTURE_RSA_ALGORITHM", "rsa-sha2-512")
    if rsa_preference not in rsa_algorithms:
        raise ValueError("Expected an RSA SHA-2 fixture algorithm")
    disabled = {"pubkeys": ["ssh-rsa", *(rsa_algorithms - {rsa_preference})],
                "keys": ["ssh-rsa", *(rsa_algorithms - {host_algorithm})]}
    fingerprint = base64.b64encode(hashlib.sha256(host_key.asbytes()).digest()).decode().rstrip("=")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener, options.log.open("w") as log:
        listener.bind(("127.0.0.1", 0))
        listener.listen(2)
        record(log, "rsaSignaturePolicy", accepted=rsa_preference)
        options.ready.write_text(json.dumps({
            "port": listener.getsockname()[1], "pin": "SHA256:" + fingerprint,
            "hostAlgorithm": host_algorithm,
        }))
        while True:
            connection, _ = listener.accept()
            with connection, paramiko.Transport(connection, disabled_algorithms=disabled) as transport:
                try:
                    transport.add_server_key(host_key)
                    transport.start_server(server=ChartLogin(authorized_keys, log))
                    record(log, "negotiatedHostKey", algorithm=transport.host_key_type)
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
