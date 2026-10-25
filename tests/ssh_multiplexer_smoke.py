"""Run the same suite over an ephemeral localhost SSH server and temporary keys."""
import argparse
import getpass
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("host", type=Path)
    parser.add_argument("--test-driver", action="store_true")
    parser.add_argument("--require-multiplexers", action="store_true")
    parser.add_argument("--tools-dir", type=Path)
    args = parser.parse_args()
    sshd = shutil.which("sshd")
    if not sshd:
        raise RuntimeError("openssh-server is required for SSH integration checks")
    with tempfile.TemporaryDirectory(prefix="vertex-ssh-") as temporary:
        root = Path(temporary)
        for name in ("host", "client"):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)], check=True)
        (root / "authorized_keys").write_bytes((root / "client.pub").read_bytes())
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        (root / "sshd_config").write_text(
            f"Port {port}\nListenAddress 127.0.0.1\nHostKey {root / 'host'}\n"
            f"PidFile {root / 'pid'}\nAuthorizedKeysFile {root / 'authorized_keys'}\n"
            f"AllowUsers {getpass.getuser()}\nStrictModes no\nPasswordAuthentication no\n"
            "KbdInteractiveAuthentication no\nUsePAM no\nUseDNS no\nPrintMotd no\n"
        )
        host_key = " ".join((root / "host.pub").read_text().split()[:2])
        (root / "known_hosts").write_text(f"[127.0.0.1]:{port} {host_key}\n")
        with (root / "sshd.log").open("w+") as log:
            server = subprocess.Popen([sshd, "-D", "-e", "-f", str(root / "sshd_config")], stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 5
                while True:
                    if server.poll() is not None:
                        log.seek(0)
                        raise AssertionError(log.read())
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(0.03)
                prefix = ["ssh", "-tt", "-F", "/dev/null", "-p", str(port), "-i", str(root / "client"),
                          "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "BatchMode=yes",
                          "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={root / 'known_hosts'}",
                          f"{getpass.getuser()}@127.0.0.1"]
                command = [sys.executable, str(Path(__file__).with_name("multiplexer_smoke.py")),
                           str(args.host), "--ssh-prefix", json.dumps(prefix)]
                if args.test_driver:
                    command.append("--test-driver")
                if args.require_multiplexers:
                    command.append("--require-multiplexers")
                if args.tools_dir:
                    command.extend(["--tools-dir", str(args.tools_dir)])
                subprocess.run(command, check=True, timeout=180)
            finally:
                server.terminate()
                try:
                    server.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


if __name__ == "__main__":
    main()
