"""PTY child used by the private Weston smoke tests to verify live replies."""
import os
from pathlib import Path
import select
import sys
import termios
import time
import tty


saved = termios.tcgetattr(0)
try:
    tty.setraw(0)

    def exchange(request, expected):
        os.write(1, request)
        received = bytearray()
        deadline = time.monotonic() + 3
        while len(received) < len(expected):
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([0], [], [], remaining)[0]:
                raise AssertionError(f"reply timeout: {bytes(received)!r}, expected {expected!r}")
            received.extend(os.read(0, 4096))
        assert bytes(received) == expected, (bytes(received), expected)

    exchange(b"\x1b[?u\x1b[c\x1b[5n", b"\x1b[?0u\x1b[?1;2c\x1b[0n")
    exchange(b"\x1b[>3u\x1b[?u", b"\x1b[?3u")
    exchange(b"\x1b[?1049h\x1b[?u\x1b[>31u\x1b[?u", b"\x1b[?0u\x1b[?31u")
    exchange(b"\x1b[?1049l\x1b[?u", b"\x1b[?3u")
    exchange(b"\x1b[<u\x1b[>4;2m\x1b[?4m", b"\x1b[>4;2m")
    exchange(b"\x1b[1;1H\x1b[6n", b"\x1b[1;1R")
    exchange(b"\x1b[?2026$p", b"\x1b[?2026;2$y")
    exchange(b"\x1b[?2026h\x1b[?2026$p", b"\x1b[?2026;1$y")
    # No further output arrives during this pause: the host must wake its deadline.
    time.sleep(0.25)
    exchange(b"\x1b[?2026$p\x1b[?2026h\x1b[?2026$p", b"\x1b[?2026;2$y\x1b[?2026;2$y")
    exchange(b"\x1b[?2026l\x1b[?2026h\x1b[?2026$p\x1b[?2026l", b"\x1b[?2026;1$y")
    exchange(b"\x1b]11;?\x07", b"\x1b]11;rgb:1515/1717/1a1a\x1b\\")
    size = os.get_terminal_size(0)
    exchange(b"\x1b[18t", f"\x1b[8;{size.lines};{size.columns}t".encode())
    os.write(1, "\x1b[38;2;17;129;253m界e\u0301👩‍💻 אבג\x1b[0m".encode())
    time.sleep(0.1)
    exchange(b"\x1bc\x1b[?u\x1b[?4m", b"\x1b[?0u\x1b[>4;0m")
    Path(sys.argv[1]).write_text("protocol replies and Unicode output passed\n")
finally:
    termios.tcsetattr(0, termios.TCSANOW, saved)
