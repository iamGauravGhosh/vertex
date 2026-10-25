"""Checksum-pinned test-only binaries; no changes to user installations."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path)
    parser.add_argument("--tools", nargs="+", default=["nvim", "hx", "lazygit", "lazydocker"])
    args = parser.parse_args()
    releases = json.loads(Path(__file__).resolve().parents[1].joinpath("tests/tui-tools.json").read_text())
    args.directory.mkdir(parents=True, exist_ok=True)
    for name in args.tools:
        release = releases[name]
        with urllib.request.urlopen(release["url"], timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != release["sha256"]:
            raise ValueError(f"{name}: checksum mismatch")
        destination = args.directory / (name + "-distribution")
        destination.mkdir(exist_ok=True)
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            archive.extractall(destination, filter="data")
        executable = (destination / release["binary"]).resolve()
        executable.chmod(0o755)
        link = args.directory / name
        if link.is_symlink():
            link.unlink()
        link.symlink_to(executable)
        print(f"{name} {release['version']}: verified {release['sha256']}", flush=True)


if __name__ == "__main__":
    main()
