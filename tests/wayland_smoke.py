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


def check_window(width, height, scale, renderer="gpu", fail_gpu=False, font=None):
    with tempfile.TemporaryDirectory(prefix="vertex-wayland-") as temporary:
        root = Path(temporary)
        environment = os.environ.copy()
        environment.pop("WAYLAND_SOCKET", None)
        environment.update(XDG_RUNTIME_DIR=temporary, WAYLAND_DISPLAY="vertex-test")
        environment.pop("__EGL_VENDOR_LIBRARY_FILENAMES", None)
        environment.update(VERTEX_RENDERER=renderer, LIBGL_ALWAYS_SOFTWARE="1")
        environment.pop("VERTEX_FONT", None)
        if font is not None:
            environment["VERTEX_FONT"] = font
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
                if fail_gpu:
                    environment["__EGL_VENDOR_LIBRARY_FILENAMES"] = str(root / "missing-egl-vendor.json")
                report = root / "size"
                result = subprocess.run(
                    [str(EXECUTABLE), "--", "/bin/sh", "-c",
                     "test -t 0 && test -t 1 && test -t 2 || exit 90; "
                     "stty size > \"$1\"; "
                     "printf '\\033[31mVertex shell output\\033[0m\\n'; sleep 0.3; "
                     "printf '\\033[1;1HX'; sleep 0.3; "
                     "printf '\\033[32m\\033]0;ignored\\007'; sleep 0.5; exit 7",
                     "vertex-test", str(report)],
                    env=environment, capture_output=True, timeout=15, check=False,
                )
                trace = result.stderr.decode(errors="replace")
                assert result.returncode == 7, trace
                assert re.search(r"wl_surface.*\.attach\(", trace), trace
                if fail_gpu:
                    assert "using CPU renderer" in trace, trace
                elif renderer == "gpu":
                    assert "using CPU renderer" not in trace, trace
                damage = re.findall(r"wl_surface.*\.damage_buffer\((-?\d+), (-?\d+), (\d+), (\d+)\)", trace)
                assert damage, trace
                assert any(int(h) < height for _, _, _, h in damage), trace
                # No frames should be committed for the final SGR/OSC-only update
                # or while the child is idle. Allow initial configure/scale frames.
                commits = re.findall(r"wl_surface.*\.commit\(\)", trace)
                assert len(commits) <= 6, trace
                rows, columns = map(int, report.read_text().split())
                assert rows > 0 and columns > 0
                print(f"Wayland {renderer} {width}x{height} scale {scale}: {columns}x{rows} cells, frame committed, child reaped")
                protocol_report = root / "protocol-report"
                protocol_environment = environment.copy()
                protocol_environment["VERTEX_BIDI"] = "auto"
                protocol_result = subprocess.run(
                    [str(EXECUTABLE), "--", sys.executable,
                     str(Path(__file__).with_name("terminal_probe.py").resolve()), str(protocol_report)],
                    env=protocol_environment, capture_output=True, timeout=20, check=False,
                )
                assert protocol_result.returncode == 0, protocol_result.stderr.decode(errors="replace")
                assert "passed" in protocol_report.read_text()
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
check_window(1280, 960, 2, font="sans")

check_window(800, 600, 1, renderer="cpu", font="sans")
check_window(800, 600, 1, renderer="auto", fail_gpu=True, font="Vertex Deliberately Unavailable Font")
