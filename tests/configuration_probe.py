"""Runs INSIDE Vertex under headless Weston; exercises live config and PTY continuity."""
import fcntl
import json
import os
from pathlib import Path
import select
import struct
import sys
import termios
import time


config, theme, report = map(Path, sys.argv[1:])
fd = sys.stdin.fileno()
previous = termios.tcgetattr(fd)
raw = termios.tcgetattr(fd)
raw[0] = 0
raw[1] = 0
raw[3] = 0
raw[6][termios.VMIN] = 0
raw[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, raw)


def atomic_write(path, text):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(text)
    temporary.replace(path)


def background():
    os.write(1, b"\x1b]11;?\x1b\\")
    received = b""
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if ready:
            received += os.read(fd, 1024)
            if b"\x1b\\" in received:
                return received
    raise AssertionError(f"no color reply: {received!r}")


def wait_background(expected):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if expected in background():
            return
        time.sleep(0.05)
    raise AssertionError(f"theme did not reload: {expected!r}")


try:
    assert os.environ["VERTEX_CONFIG_PROBE"] == "configured"
    initial_size = os.get_terminal_size(fd)
    assert b"1111/2222/3333" in background()
    os.write(1, b"\x1b]2;Vertex configuration probe\x07preserved output\r\n")
    atomic_write(theme, "[colors]\nbackground='#445566'\n")
    wait_background(b"4444/5555/6666")
    original = config.read_text()
    # A font/padding reload must resize the original PTY, without restarting us.
    atomic_write(config, original + "\n[font]\nsize=14\n[window.padding]\nleft=120\nright=120\ntop=80\nbottom=80\n")
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and os.get_terminal_size(fd) == initial_size:
        time.sleep(0.05)
    resized = os.get_terminal_size(fd)
    assert resized.columns < initial_size.columns and resized.lines < initial_size.lines
    rows, columns, width, height = struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, bytes(8)))
    assert columns == resized.columns and rows == resized.lines and width > 0 and height > 0
    atomic_write(config, "font.size='invalid'\n")
    time.sleep(0.3)
    assert b"4444/5555/6666" in background()
    assert os.get_terminal_size(fd) == resized
    atomic_write(config, original)
    wait_background(b"4444/5555/6666")
    report.write_text(json.dumps({"passed": True, "initial": list(initial_size), "resized": list(resized), "pid": os.getpid()}))
finally:
    termios.tcsetattr(fd, termios.TCSANOW, previous)
