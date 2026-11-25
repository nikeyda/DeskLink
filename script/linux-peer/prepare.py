import gzip
import base64
import hashlib
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
configuration.write_text("[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=leaf\n"
                         "[dn]\nCN=localhost\n[leaf]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n"
                         "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
                         "extendedKeyUsage=serverAuth\n")
subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "1",
                "-config", str(configuration), "-keyout", str(tls / "key.pem"), "-out", str(tls / "cert.pem")],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
(tls / "key.pem").chmod(0o600)
der = subprocess.check_output(["openssl", "x509", "-in", str(tls / "cert.pem"), "-outform", "DER"])
(root / "tls-pin").write_text("SHA256:" + base64.b64encode(hashlib.sha256(der).digest()).decode().rstrip("="))
shutil.copyfile(Path(__file__).with_name("desklink-init"), extra / "desklink-init")
shutil.copyfile(Path(__file__).with_name("start-wayland"), extra / "start-wayland")
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
