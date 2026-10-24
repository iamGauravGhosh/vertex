"""CI smoke checks using private headless Weston instances, never the desktop.

Usage: python3 tests/wayland_smoke.py zig-out/bin/vertex
Requires Weston with its headless backend and kiosk shell.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time


EXECUTABLE = Path(sys.argv[1]).resolve()


def wait_for(predicate, message, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(message)


def check_window(width, height, scale):
    with tempfile.TemporaryDirectory(prefix="vertex-wayland-") as temporary:
        root = Path(temporary)
        environment = os.environ.copy()
        environment.pop("WAYLAND_SOCKET", None)
        environment.update(XDG_RUNTIME_DIR=temporary, WAYLAND_DISPLAY="vertex-test")
        with (root / "weston.log").open("w+") as compositor_log:
            weston = subprocess.Popen(
                ["weston", "--backend=headless-backend.so", "--renderer=pixman",
                 "--shell=kiosk-shell.so", "--socket=vertex-test", "--no-config",
                 "--idle-time=0", f"--width={width}", f"--height={height}", f"--scale={scale}"],
                env=environment, stdout=compositor_log, stderr=subprocess.STDOUT,
            )
            try:
                wait_for(lambda: (root / "vertex-test").exists() or weston.poll() is not None,
                         "Weston did not create its socket")
                if weston.poll() is not None:
                    raise AssertionError((root / "weston.log").read_text())
                environment["WAYLAND_DEBUG"] = "client"
                report = root / "size"
                result = subprocess.run(
                    [str(EXECUTABLE), "--", "/bin/sh", "-c",
                     "test -t 0 && test -t 1 && test -t 2 || exit 90; "
                     "stty size > \"$1\"; "
                     "printf '\\033[31mVertex shell output\\033[0m\\n'; sleep 0.3; exit 7",
                     "vertex-test", str(report)],
                    env=environment, capture_output=True, timeout=15, check=False,
                )
                trace = result.stderr.decode(errors="replace")
                assert result.returncode == 7, trace
                assert re.search(r"wl_surface.*\.attach\(", trace), trace
                rows, columns = map(int, report.read_text().split())
                assert rows > 0 and columns > 0
                print(f"Wayland {width}x{height} scale {scale}: {columns}x{rows} cells, frame committed, child reaped")
                # A disconnected compositor must also hang up and reap a shell
                # that is still running, rather than leave a background session.
                pid_file = root / "child-pid"
                child = subprocess.Popen(
                    [str(EXECUTABLE), "--", "/bin/sh", "-c",
                     "printf '%s' $$ > \"$1\"; while :; do sleep 0.1; done",
                     "vertex-test", str(pid_file)],
                    env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                )
                try:
                    wait_for(lambda: pid_file.exists() and bool(pid_file.read_text()),
                             "Shell did not start")
                    child_pid = int(pid_file.read_text())
                    weston.terminate()
                    weston.wait(timeout=5)
                    assert child.wait(timeout=5) == 1
                    try:
                        os.kill(child_pid, 0)
                    except ProcessLookupError:
                        pass
                    else:
                        raise AssertionError(f"Shell {child_pid} survived compositor disconnect")
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
                return rows, columns
            finally:
                weston.terminate()
                try:
                    weston.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    weston.kill()
                    weston.wait()


large = check_window(800, 600, 1)
small = check_window(640, 480, 1)
assert small[0] < large[0] and small[1] < large[1], (large, small)
check_window(1280, 960, 2)
