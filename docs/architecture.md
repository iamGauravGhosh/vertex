# Architecture

Vertex is a terminal emulator written in Zig. The Linux MVP connects a native
Wayland window, GPU/CPU renderer, and interactive shell PTY to the reusable VT parser
and resizable screen model. A separate stdin trace CLI remains available.

## Responsibilities

- `src/main.zig`: select a window session or headless CLI and report errors.
- `src/cli.zig`: window-launch selection, `vertex parse`, and command-line help.
- `src/terminal/`: allocation-free parsing and event tracing, plus an owned screen
  grid with colors, attributes, cursor state, editing, and scrolling regions.
  Resizing preserves the top-left overlap without reflow. Scrollback remains a future milestone. `Session` owns main/alternate grids,
  negotiated input modes, keyboard stacks, and replies.
- `src/renderer/`: Fontconfig font selection, HarfBuzz shaping, bounded FreeType
  atlas pages, row/cursor damage, GLES3 rendering, and a CPU reference backend.
- `src/platform/`: native Wayland globals, xdg-shell, shared-memory buffers,
  xkbcommon keyboard state, timer-based repeat, pointer reporting, asynchronous
  clipboard receiving, text-input-v3 IME, PTY, and child lifecycle.
- `assets/fonts/`: reserved for future bundled fonts; the MVP uses system fonts.
- `tests/`: public-module consumer and executable smoke checks.

## Data flow

```text
Keyboard input -> PTY -> shell
Shell output -> PTY -> terminal parser -> screen state -> renderer
Wayland configure -> screen.resize -> TIOCSWINSZ -> shell SIGWINCH
```

Keep the terminal model independent of the rendering backend and OS APIs so its
behavior can be tested without opening a window or launching a shell.

The parser and screen model are exported as the `vertex_terminal` Zig module.
The parser accepts byte chunks and emits syntax events; it does not set terminal
modes, perform screen updates, write responses, or access the clipboard.
`Screen.handle` consumes those events and applies supported text, style, cursor,
and scrolling commands. The screen allocates at initialization, resize, and
when extending stored text clusters; ASCII and grid editing
remain allocation-free. `Screen.apply` reports errors; parser-handler adapters
latch them for retrieval after a feed. See [the parser guide](vt-parser.md) for syntax and
[the screen guide](screen.md) for command execution and ownership.

## Text layout and atlas ownership

Each row caches shaped glyph IDs, font identity, positions, source cell spans,
and a content fingerprint. Unicode 15.1 graphemes occupy one or two columns;
continuation cells are never shaped independently. Fontconfig supplies fallback
faces for complete clusters in stable Fontconfig order, with separate sorted sets
for regular, bold, italic, and bold-italic styles. The GUI owns a typed TOML configuration snapshot and applies environment
overrides. Configuration files and imports are watched through filtered directory
inotify watches in the main poll loop. Reload prepares a replacement renderer,
watch set, and grid storage before swapping snapshots; rejected candidates retain
the current renderer, settings, and PTY. Optional ligatures default off; configured
HarfBuzz features never disable required complex-script shaping. Explicit
renderer initializers ignore configuration and the environment; `initWithOptions`
accepts families, point size, ligature/features/spacing options, and an optional
fixture directory. The default is
`monospace` at 12 pt, sized at 96 logical DPI with FreeType. Monospace
and proportional faces both use the primary font's `M` advance for cell width,
with a positive metrics fallback when `M` is unavailable. HarfBuzz shapes
script/style/font/direction runs. Private-use icons form separate runs and do not
trigger emoji font preference; actual Unicode emoji-presentation characters do.

Raster ink bounds and advances determine fitting for each complete shaped
cluster. Proportional clusters are centered in their assigned columns, and
overflowing clusters shrink uniformly while preserving mark offsets and ordinary
text baselines. Private-use icons fit both cell dimensions and are centered
vertically; genuinely wide icons can borrow one immediately adjacent visual space
with identical style and hyperlink. `PositionedGlyph.end` retains the logical
span, while `paint_end` records the expanded clip span. Row generations account
for adjacent-space edits. Box drawing, block elements, Braille, and basic Powerline
separators bypass fonts and use shared, cell-aligned atlas masks. Fitted bitmap
dimensions and positions are cached in the row; Unicode
column widths and input coordinate mapping remain independent of font advances.
`VERTEX_BIDI=auto` uses FriBidi to resolve soft-wrapped logical paragraphs, then
reorders each physical row while retaining logical-to-visual column mappings.
The default `off` preserves fixed visual columns. Bidi paragraph edits invalidate
presentation across the screen to account for changes on neighboring lines.

FreeType rasterizes masks and color bitmaps/COLRv0 glyphs into four bounded,
lazily allocated 1024×1024 RGBA atlas pages (16 MiB total pixel storage). Masks
store premultiplied white; color glyphs retain premultiplied RGBA. Shelf packing,
LRU recycling, padding, and bounded tiled scratch storage remain shared between
CPU and GPU. Raw glyph metrics are cached by face and style; atlas keys also
include fitted raster dimensions, so a glyph shared by a multi-cell ligature and
a single-cell icon cannot reuse the wrong bitmap. Shared area resampling retains
thin strokes and premultiplied color before atlas upload. Both backends composite
premultiplied pixels; the GPU flushes pending batches before atlas reuse.
Row caches retain content fingerprints rather than pointers into mutable cluster
storage. Scale changes resize all loaded faces and invalidate rows and atlases.

Clipboard transfers use nonblocking pipes polled alongside Wayland, PTY, and
repeat timers. Only complete bounded text transfers become paste transactions.
A write offset preserves transaction ordering through short PTY writes.
Text-input-v3 batches preedit/commits on `done`; preedit draws on a temporary grid
and never alters application-owned terminal cells. The terminal does not advertise
surrounding text because it cannot infer the application's editable buffer.

## Image extension boundary

APC, OSC, and DCS payload events provide transport for Kitty, iTerm2, and
Sixel handlers. APC/OSC streaming is opt-in; DCS always streams after its header.
Large payloads need no whole-message buffer in the parser.

Image support follows this path:

```text
Parser events -> protocol handler -> decoder -> image store/placements -> renderer
```

`GraphicsProtocol` recognizes protocol headers, assembles transfers, decodes
base64/zlib, applies budgets, and generates replies. `Sixel` produces pixels;
an injected decoder handles encoded image files. `Screen.graphics` owns immutable
reference-counted pixel buffers and screen-local placements. Both painters draw
the same clipped, layered pixels. Incomplete transfers are discarded. OSC 8
targets are owned independently of SGR styles and retained by cells; the desktop
adapter opens validated targets on Ctrl+click. See [media](media.md).

## Linux integration

The executable uses system libraries through build-time translated headers.
`wayland-scanner` generates stable xdg-shell declarations and protocol metadata
in the build cache. Only generated protocol code is C; application logic is Zig.
`-Dgui=false` omits the GUI libraries and code generation entirely.

One loop dispatches Wayland events, reads bounded PTY batches, flushes queued
keyboard bytes, and handles keyboard-repeat timers. It follows Wayland's
prepare/read/cancel contract and enables writable polling when a flush would
block. Frames are scheduled only for damaged rows, visible cursor changes, or
window changes, and remain throttled by Wayland frame callbacks. Output enter/leave
and scale events determine the integer buffer scale independently of logical
terminal dimensions.

`VERTEX_RENDERER` selects `auto` (default), `gpu`, or `cpu`. The EGL backend owns
a GLES3 context, Wayland EGL window, and persistent framebuffer texture. Only
damaged rows are repainted; the entire retained texture is blitted to each EGL
backbuffer so correctness does not depend on buffer age or preservation. KHR/EXT
swap-with-damage is used when available, with bottom-left pixel rectangles;
otherwise presentation uses ordinary swaps. A context or presentation failure
in auto mode switches permanently to CPU after destroying EGL resources.

Both backends retain premultiplied alpha. The default background and padding
use configured opacity while text and explicit cell backgrounds remain opaque.
A shared padded viewport translates drawing, image clips, IME rectangles, damage,
and pointer coordinates. Session-owned theme colors also answer color queries.
Cursor blink deadlines wake the poll loop without repainting idle windows.

The CPU backend keeps a canonical ARGB8888 image and two shared-memory buffers.
Each buffer accumulates its own pending rows, including while busy, and catches
up from the canonical image only after release. Resize retires incompatible
buffers until the compositor releases them. Initialization, resize, scale, and
backend changes repaint the whole surface, including unused padding.

The screen exposes borrowed row damage with explicit acknowledgment. Damage is
cleared only after presentation succeeds, so deferred frames retain every edit.
Cursor rows are tracked separately against the last presented cursor; SGR-only
changes and ignored protocol strings do not schedule frames.

The PTY child receives a new session and controlling terminal, reset signal
dispositions, inherited working directory, and terminal environment variables.
A close-on-exec error pipe reports launch failure before entering the event loop.
The parent reaps child exits even when descendants retain the slave. Closing
the window hangs up the foreground job and shell session, with bounded waiting
and forced termination of an unresponsive shell.

Headless tests cover parsing, screen resizing, key encoding, PTY I/O and lifecycle,
and in-memory rendering. Surfaceless Mesa tests compare incremental GPU and CPU
pixels with full redraws, with at most one channel value of blending tolerance.
CI requires these GPU tests using `VERTEX_TEST_GPU=1` and
`LIBGL_ALWAYS_SOFTWARE=1`; without the requirement variable, unavailable headless
EGL causes the GPU comparison test to skip. CI also starts private headless Weston
instances at different geometries/scales, forces both backends, injects an EGL
initialization failure to verify auto fallback, and checks partial damage and
idle frame suppression. The optional `VERTEX_TEST_WAYLAND=1` integration
test opens a real window, renders a short command, and checks its exit status.
Scrollback, selection/copy UI, image animation, and full xterm compatibility remain future work.
