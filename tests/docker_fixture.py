"""Populate an explicitly isolated Docker daemon without pulling network images."""
import argparse
import io
from pathlib import Path
import subprocess
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument("endpoint")
parser.add_argument("--busybox", type=Path, default=Path("/bin/busybox"))
args = parser.parse_args()
if not args.endpoint.startswith("unix://") or not Path(args.endpoint[7:]).name.startswith("vertex-"):
    raise ValueError("expected a dedicated unix://.../vertex-*.sock fixture daemon")
image = io.BytesIO()
with tarfile.open(fileobj=image, mode="w") as archive:
    archive.add(args.busybox, arcname="bin/busybox", recursive=False)
prefix = ["docker", "--host", args.endpoint]
subprocess.run([*prefix, "import", "-", "vertex-tui-fixture:local"], input=image.getvalue(), check=True, capture_output=True, timeout=30)
subprocess.run([*prefix, "run", "--detach", "--name", "vertex-tui-fixture", "vertex-tui-fixture:local",
                "/bin/busybox", "sh", "-c", "while :; do echo VERTEX_DOCKER_LOG; /bin/busybox sleep 1; done"], check=True, capture_output=True, timeout=30)
print("Disposable Docker fixture is ready")
