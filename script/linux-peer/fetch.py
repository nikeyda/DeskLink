"""Fetch the known Alpine artifacts for this isolated interoperability test."""
import concurrent.futures
import csv
import hashlib
from pathlib import Path
import subprocess
import sys

base = "https://dl-cdn.alpinelinux.org/alpine/v3.23/"
cache = Path(sys.argv[1])


def fetch(entry):
    destination = cache / entry["path"]
    size = int(entry["size"])
    expected = entry["sha256"]
    if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() == expected:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".download")
    digest = hashlib.sha256()
    with temporary.open("wb") as out:
        for start in range(0, size, 1024 * 1024):
            end = min(start + 1024 * 1024, size) - 1
            chunk = subprocess.check_output([
                "curl", "-fLsS", "--retry", "3", "--max-time", "150",
                "--range", f"{start}-{end}", base + entry["upstream"],
            ])
            if len(chunk) != end - start + 1:
                raise ValueError("Unexpected download length for " + destination.name)
            digest.update(chunk)
            out.write(chunk)
    if digest.hexdigest() != expected:
        raise ValueError("Checksum mismatch for " + destination.name)
    temporary.replace(destination)


entries = []
for manifest in ["alpine.tsv", "wayland.tsv"]:
    with Path(__file__).with_name(manifest).open() as source:
        entries.extend(csv.DictReader(source, delimiter="\t"))
with concurrent.futures.ThreadPoolExecutor(max_workers=8) as workers:
    list(workers.map(fetch, entries))
print(f"Verified {len(entries)} Alpine fixture files.")
