import gzip
import base64
import hashlib
import ipaddress
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
rootfs = root / "rootfs.tar.gz"
if hashlib.sha256(rootfs.read_bytes()).hexdigest() != "3f1bd6811370264cc363bb991ff15ac67621b239ea6e25ff2eb22af3d0641473":
    raise ValueError("Alpine minirootfs checksum")
zboot = (root / "vmlinuz").read_bytes()
if zboot[4:8] != b"zimg" or zboot[24:28] != b"gzip":
    raise ValueError("Alpine EFI zboot")
offset, length = struct.unpack_from("<II", zboot, 8)
kernel = gzip.decompress(zboot[offset:offset+length])
if kernel[56:60] != b"ARM\x64":
    raise ValueError("Expected a 64-bit ARM Linux Image")
(root / "Image").write_bytes(kernel)
extra = root / "extra"
tls = extra / "test-tls"
tls.mkdir(mode=0o700, exist_ok=True)
configuration = root / "fixture-tls.cnf"
subject_names = "DNS:localhost,IP:127.0.0.1"
if len(sys.argv) > 2:
    subject_names += ",IP:" + str(ipaddress.IPv6Address(sys.argv[2]))
configuration.write_text("[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=leaf\n"
                         f"[dn]\nCN=localhost\n[leaf]\nsubjectAltName={subject_names}\n"
                         "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                         "extendedKeyUsage=serverAuth\n")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "1",
                "-config", str(configuration), "-keyout", str(tls / "key.pem"), "-out", str(tls / "cert.pem")],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
(tls / "key.pem").chmod(0o600)
der = subprocess.check_output(["openssl", "x509", "-in", str(tls / "cert.pem"), "-outform", "DER"])
(root / "tls-pin").write_text("SHA256:" + base64.b64encode(hashlib.sha256(der).digest()).decode().rstrip("="))
rsa_mode = tls / "rsa-mode"
rsa_bits = os.environ.get("DESKLINK_TEST_RSA_AES")
if rsa_bits:
    security = {"128": "RA2", "256": "RA2_256,RA2"}[rsa_bits]
    account = "account" if os.environ.get("DESKLINK_TEST_RSA_ACCOUNT") == "1" else "password"
    rsa_mode.write_text(f"{security} {account}\n")
else:
    rsa_mode.unlink(missing_ok=True)
if rsa_bits or os.environ.get("DESKLINK_TEST_PI_DESKTOP_ACCOUNT") == "1":
    spki = subprocess.check_output(["openssl", "pkey", "-in", str(tls / "key.pem"), "-pubout", "-outform", "DER"])
    (root / "rsa-pin").write_text("SHA256:" + base64.b64encode(hashlib.sha256(spki).digest()).decode().rstrip("="))
shutil.copyfile(Path(__file__).with_name("desklink-init"), extra / "desklink-init")
shutil.copyfile(Path(__file__).with_name("start-wayland"), extra / "start-wayland")
shutil.copyfile(Path(__file__).with_name("start-raspios-wayland"), extra / "start-raspios-wayland")
if not (extra / "modloop").exists():
    os.link(root / "modloop", extra / "modloop")
(extra / "desklink-init").chmod(0o755)
prepared = root / "guest-initrd.partial"
with prepared.open("wb") as out:
    with (root / "initramfs").open("rb") as initial:
        shutil.copyfileobj(initial, out)
    out.flush()
    subprocess.run(["bsdtar", "--format", "newc", "-czf", "-", "@" + str(rootfs), "-C", str(extra), "."],
                   stdout=out, check=True)
prepared.replace(root / "guest-initrd")
print("Linux Image and isolated RAM disk ready")
