"""Display a static image using direct Kitty/iTerm2 data, or a Sixel test swatch."""
import argparse
import base64
from pathlib import Path
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("image", nargs="?", type=Path)
parser.add_argument("--protocol", choices=("kitty", "iterm", "sixel"), default="kitty")
args = parser.parse_args()
output = sys.stdout.buffer
if args.protocol == "sixel":
    output.write(b'\x1bP0;1q"1;1;96;48#1;2;100;25;10')
    for row in range(8):
        output.write(b"!96~" + (b"-" if row < 7 else b""))
    output.write(b"\x1b\\\r\n")
else:
    if args.image is None:
        parser.error("an image path is required for Kitty/iTerm2 output")
    data = args.image.read_bytes()
    if len(data) > 32 * 1024 * 1024:
        parser.error("image exceeds the 32 MiB transfer limit")
    if args.protocol == "kitty" and not data.startswith(b"\x89PNG\r\n\x1a\n"):
        parser.error("Kitty file output requires a PNG; use iTerm2 for JPEG/GIF")
    encoded = base64.b64encode(data)
    if args.protocol == "kitty":
        for offset in range(0, len(encoded), 4096):
            chunk = encoded[offset:offset + 4096]
            header = b"a=T,f=100,q=2," if offset == 0 else b""
            more = int(offset + len(chunk) < len(encoded))
            output.write(b"\x1b_G" + header + f"m={more};".encode() + chunk + b"\x1b\\")
        output.write(b"\r\n")
    else:
        output.write(b"\x1b]1337;File=inline=1:" + encoded + b"\x07")
output.flush()
