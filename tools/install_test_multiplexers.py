"""Install checksum-pinned Linux x86_64 test tools into an explicit directory.

These tools are never runtime dependencies of Vertex.
"""
import argparse
import hashlib
import io
from pathlib import Path
import tarfile
import subprocess
import tempfile
import urllib.request


RELEASES = (
    ("zellij", "https://github.com/zellij-org/zellij/releases/download/v0.45.1/"
     "zellij-no-web-x86_64-unknown-linux-musl.tar.gz",
     "d7bda1e18c30a688833ae7627f1d6a253bbba5349a4bc48e4f0ec008aaf75ed1", True),
    ("herdr", "https://github.com/herdrdev/herdr/releases/download/v0.9.5/herdr-linux-x86_64",
     "14d9e8bc8b4a9e0118d77c32266f76d461f09b40342eb23752960bd89f59929d", False),
)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--build-tmux", action="store_true", help="CI-only: compile the pinned tmux source release")
    args = parser.parse_args()
    args.directory.mkdir(parents=True, exist_ok=True)
    for name, url, expected, archive in RELEASES:
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        actual = hashlib.sha256(data).hexdigest()
        if actual != expected:
            raise ValueError(f"{name}: SHA256 mismatch: {actual}")
        if archive:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as package:
                members = [item for item in package.getmembers() if item.isfile() and Path(item.name).name == name]
                if len(members) != 1:
                    raise ValueError(f"{name}: unexpected archive")
                data = package.extractfile(members[0]).read()
        destination = args.directory / name
        destination.write_bytes(data)
        destination.chmod(0o755)
        print(f"installed {name}: verified {expected}", flush=True)
    if args.build_tmux:
        url = "https://github.com/tmux/tmux/releases/download/3.8/tmux-3.8.tar.gz"
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        expected = "e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e"
        if hashlib.sha256(data).hexdigest() != expected:
            raise ValueError("tmux: SHA256 mismatch")
        with tempfile.TemporaryDirectory(prefix="vertex-tmux-source-") as temporary:
            root = Path(temporary)
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as package:
                package.extractall(root, filter="data")
            source = root / "tmux-3.8"
            subprocess.run(["./configure", "--disable-utf8proc"], cwd=source, check=True)
            subprocess.run(["make", "-j2"], cwd=source, check=True)
            destination = args.directory / "tmux"
            destination.write_bytes((source / "tmux").read_bytes())
            destination.chmod(0o755)
        print(f"installed tmux 3.8: verified source {expected}", flush=True)


if __name__ == "__main__":
    main()
