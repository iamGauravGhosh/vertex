# Terminal protocols

`vertex_terminal.Session` is the parser handler for interactive terminals. It
owns active and inactive `Screen` values, input modes, independent main/alternate
Kitty stacks, and an ordered reply queue. It has no libc or GUI dependencies.
OSC 8 targets are supported by default. `initWithOptions` can enable Kitty,
Sixel, and iTerm2 image handling and inject an encoded-file decoder; see
[hyperlinks and inline images](media.md). GUI sessions enable images.

```zig
var session = try vt.Session.init(allocator, 24, 80);
defer session.deinit();
var parser = vt.Parser.initWithOptions(.{ .osc_mode = .streaming });
// Set the host's monotonic clock before feeding output; wake at sync_deadline_ms.
const held = session.presentationHeld(now_ms);
_ = held;
parser.feed(output_bytes, &session);
if (session.takeError()) |err| return err;
try session.drainReplies(writer);
const screen = session.activeScreen();
const modes = session.getModes();
const bytes = try vt.Input.encodeKey(buffer, event, modes);
```

The screen pointer addresses the active screen field; screen switches exchange
its contents and invalidate borrowed rows. `resize()` prepares both grids before
committing and retains input modes. Default public sessions preserve top-left
overlap. Optional `Session.Options` history/reflow settings enable main-screen
text reflow; alternate screens keep their fixed grid.
RIS (`ESC c`) resets both screens, negotiated modes, and stacks. Reply draining
acknowledges bytes only after the writer succeeds; a writer that partially writes
before failing must not retry the whole queue without accounting for its progress.
The Linux adapter moves replies into its nonblocking PTY queue before draining.

`presentationHeld(now_ms)` updates the host-supplied monotonic clock and reports
whether presentation should wait. Mode 2026 holds presentation for at most 150 ms;
the host must poll its deadline even when output stops. Repeated begins do not
extend the deadline. After timeout, further begins are ignored until an explicit
end or RIS. Parsing, input, replies, and clipboard handling continue during a hold.
Damage is acknowledged only after a successful presentation.

Set `session.geometry` from the host's current surface and cell sizes in physical
pixels. CSI 14/16/18 `t` query surface pixels, cell pixels, and terminal rows/columns.
Unset pixel geometry produces no fabricated reply. DECRQM reports implemented
private modes as set/reset and unknown modes as unrecognized. Secondary device
attributes identify a conservative VT100 class rather than claiming VT420 support.
XTGETTCAP handles `TN`, `Co`/`colors`, `RGB`/`Tc`, `Ms`, `Sync`, `Su`, `Smulx` and `Setulc`; unknown names
receive a failure reply. DECRQSS reports SGR, vertical/horizontal margins and cursor
shape; other status strings receive a failure reply. These are bounded handlers,
not general DCS passthrough. OSC 4, 10, and 11 queries use the renderer's shared
palette and defaults. OSC 4/10/11/12 mutate colors, and 104/110/111/112 restore
the configured baseline. Hosts use `setTheme()` for configuration reload and
observe `color_generation` to update painters. `takeBell()` consumes a pending bell.

Input modes include DEC application cursor/keypad, focus, bracketed paste, and
mouse tracking/encoding. `Session` applies DECSET/DECRST, alternate screens
47/1047/1048/1049, Kitty `CSI =/>/</? ... u`, and xterm modifyOtherKeys controls.
Kitty stacks have 32 saved entries; overflowing pushes evict the oldest entry.
Queries capture state at their position in the output stream. Malformed
subparameter mode lists are ignored.

`Input.Key` uses Unicode unshifted key codes and Kitty functional identifiers;
`shifted` and `base` carry optional alternate identities. Actions distinguish
press, repeat, and release. XKB keysyms and physical key names are translated
only in the Linux adapter. All five Kitty enhancement flags are supported;
ordinary input defaults to legacy UTF-8/control encodings. Active Kitty flags
take precedence over modifyOtherKeys levels 0–2. Paste bindings are local.

`Input.Pointer` coordinates are zero-based; wire coordinates are one-based.
Tracking supports 9, 1000, 1002, and 1003; encoding supports legacy, 1006, and
1016. Legacy reports outside the 223-column/row limit are suppressed. Mouse
coordinates refer to visual cells even when bidi rendering is enabled. Highlight
tracking (1001), UTF-8 mouse encoding (1005), and urxvt encoding (1015) are omitted.

`Input.paste()` creates one owned transaction, strips NUL/ESC, normalizes line
endings to CR, and conditionally adds mode-2004 framing. The Linux clipboard
receiver caps transfers at 8 MiB and waits for EOF before enqueueing. Queue write
offsets preserve order across short writes and `EAGAIN`. Focus loss cancels an
unfinished clipboard receive.

With streaming OSC enabled, `takeClipboard()` transfers ownership of the newest
complete OSC 52 write (`c` or empty selection) as an optional owned byte slice.
The host must free it, including an empty slice used to clear the clipboard.
Standard padded base64 is decoded incrementally up to 8 MiB. Invalid, oversized,
cancelled, interrupted, and incomplete writes never replace the previous complete
write. Queries (`?`) and other selection targets are ignored. Buffered parser
consumers also support small writes within the parser's existing 4096-byte limit.
The GUI enables streaming; the event-trace CLI keeps its previous defaults.

Wayland publication waits for focus and a valid keyboard/button input serial;
focus loss clears that serial. Clipboard sources advertise UTF-8 plain text.
At most four asynchronous sends are active, sharing a 64 KiB write budget per
event-loop turn. Each owns its bytes so replacing a source cannot invalidate an
in-flight send. Slow or closed recipients do not block keyboard/PTY processing.

Unicode segmentation data and its conformance fixture are pinned to 18.0.0.
Regenerate with `python3 tools/generate_unicode.py /path/to/UCD.zip`. Generated
tables and original test fonts are committed; builds perform no downloads.
`tools/generate_test_fonts.py` rebuilds the tiny MIT-licensed fonts using
FontTools 4.60.1. Bidi behavior uses the installed FriBidi Unicode implementation.

## History, reflow and selection API

`Session.init()` keeps the dependency-free fixed-grid defaults. Hosts can use
`initWithOptions(..., .{ .history = true, .history_lines = 10000,
.history_bytes = 64 * 1024 * 1024, .reflow = true })` to enable the history
layer. Existing `images` and `decoder` options remain available.

`historyCount()`, `scroll(lines)`, `live()`, `point(row, column)`, `select(first,
end)`, `selectWord(point, whole_row)` and `copySelection(allocator)` operate
without OS dependencies. Positions use row IDs stable during output scrolling
and cell columns; selection
ends are exclusive. `copySelection()` returns owned UTF-8. `viewport()` returns
an owned Screen snapshot for history/selection presentation; deinitialize it
after use. Cached external positions must be reacquired after a resize; Session
remaps its own selection. Its cursor is hidden while scrolled. None of these APIs move the live
application cursor. Resize remaps anchors transactionally and retains the old
screen/history on allocation failure. Images remain live-grid placements.

Grapheme mode 2027 reports permanently set. ANSI 4/20 queries report the actual
insert/newline state. `DECRQSS m` reports current SGR, including underline style
and colors, so application feature probes can succeed without terminal-name
heuristics. See [application checks and limits](compatibility.md).

Protocol references: [Kitty keyboard](https://sw.kovidgoyal.net/kitty/keyboard-protocol/),
[xterm controls](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html),
[Unicode segmentation](https://www.unicode.org/reports/tr29/), and the installed
Wayland text-input-v3/primary-selection protocol XML files.
