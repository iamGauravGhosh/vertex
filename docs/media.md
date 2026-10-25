# Hyperlinks and inline images

Hover over an OSC 8 hyperlink or a printed HTTP/HTTPS URL to underline it.
Ctrl+left-click opens the target with the desktop's default application through
`xdg-open`. HTTP, HTTPS, mailto, and absolute local file URIs are supported;
remote file hosts and other schemes are rejected. The click and its drag/release
are handled locally even when the application has enabled mouse reporting.
Unmodified mouse input keeps its existing behavior.

```sh
printf '\033]8;;https://example.com\033\\Open example\033]8;;\033\\\n'
printf 'A detected URL: https://example.com/docs\n'
printf '\033]8;;file:///tmp\033\\Open /tmp\033]8;;\033\\\n'
```

Explicit links support the OSC 8 `id` parameter, both BEL and ST terminators,
Unicode labels, and application-supplied styling. Plain URLs join soft-wrapped
rows, trim sentence punctuation and unmatched closing brackets, and are limited
to 4096 bytes. Pointer lookup follows bidi visual order. Links do not open until
clicked, and opener failures do not close the terminal.

## Static image support

Both CPU and GPU renderers support the following protocols:

| Protocol | Supported features |
| --- | --- |
| Kitty APC `G` | Direct RGB/RGBA/PNG transfers, chunking, zlib, query replies, image IDs/numbers, multiple placements, cropping, cell sizing, offsets, cursor policy, z ordering, and deletion |
| Sixel DCS `q` | Raster attributes, repeats, RGB/HLS palettes, transparency, aspect ratios, scrolling/display modes, private color registers, cursor-right mode, and capability queries |
| iTerm2 OSC 1337 | Inline `File`, `MultipartFile`/`FilePart`/`FileEnd`, cell/pixel/percentage/auto sizing, aspect-ratio control, PNG/JPEG/GIF decoding |

GIFs show their first frame. Animation, Kitty Unicode placeholders, relative
placements, indexed pixel formats, file/shared-memory transports, and iTerm2
downloads are not implemented. Unsupported Kitty operations receive an error
unless replies are suppressed with `q`. Unnamed Kitty images are released when
their last placement disappears; named images remain cached until deletion,
screen clearing, or reset.

From the repository directory, display the bundled fixtures:

```sh
python3 tools/show_image.py tests/images/rgba.png --protocol kitty
python3 tools/show_image.py tests/images/rgb.jpg --protocol iterm
python3 tools/show_image.py --protocol sixel
```

The helper sends direct data, making it suitable over SSH. External viewers
must select a supported protocol and use direct transfers. For example,
`kitten icat --transfer-mode=stream image.png` avoids filesystem transfers.
Multiplexer image support depends on its forwarding capabilities; Vertex does
not implement new tmux DCS passthrough unwrapping or Kitty Unicode placeholders.
`TERM` remains `xterm-256color`; protocol queries, or explicit viewer options,
should be used to select image output.

Images scroll with their screen and are clipped at scrolling margins and resize
boundaries. Main and alternate screens have separate images. Clear-screen and
reset remove images. Ordinary text erasure leaves Kitty placements intact;
Sixel/iTerm2 coverage follows text overwrites, erasure, and character editing.
Rendering uses nearest-neighbor sampling, premultiplied alpha, and row damage.
GPU fallback preserves the same image state.

## Resource limits and embedding

Transfers are accepted only after successful termination and decoding. Invalid,
cancelled, incomplete, and oversized transfers leave completed images intact.
Defaults are 32 MiB decoded transfer data, 8192 pixels per dimension, 64 MiB per
bitmap, 128 MiB shared resident bitmap/assembly storage, and 1024 assets or
placements per screen. GPU image textures use an additional cache capped at
64 MiB and eight textures. Decoder scratch allocations are independently capped
at 128 MiB per call. Decoding runs synchronously at the completion of a transfer;
large images can briefly delay the event loop.

The parser remains allocation-free. Existing `Session.init` consumers keep image
handling disabled. Enable it explicitly when embedding:

```zig
var session = try vt.Session.initWithOptions(allocator, 24, 80, .{
    .images = true,
    .decoder = myImageDecoder,
});
defer session.deinit();
var parser = vt.Parser.initWithOptions(.{
    .osc_mode = .streaming,
    .apc_mode = .streaming,
});
// Fill session.geometry with surface/cell pixel sizes before image output.
parser.feed(bytes, &session);
if (session.takeError()) |err| return err;
```

`Graphics.Decoder` receives an allocator and complete encoded file bytes and
returns `Graphics.Decoded` with width, height, and allocator-owned straight-alpha
RGBA bytes. Invalid dimensions and byte counts are checked again before storage.
A null decoder still supports Kitty raw pixels and Sixel. The GUI supplies the
vendored memory-only stb PNG/JPEG/GIF decoder; the portable module needs no C or
GUI libraries. The upstream revision and license are in `vendor/stb`.

`Screen.getLink` borrows an explicit target; `Links.find` returns an owned URI and
logical cell range for explicit or detected links. Free its URI with the supplied
allocator. `Screen.getImages` borrows placements; bitmap pixels and link metadata
must be treated as immutable. Screen mutations invalidate borrowed metadata.
