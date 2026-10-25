# Terminal protocols

`vertex_terminal.Session` is the parser handler for interactive terminals. It
owns active and inactive `Screen` values, input modes, independent main/alternate
Kitty stacks, and an ordered reply queue. It has no libc or GUI dependencies.

```zig
var session = try vt.Session.init(allocator, 24, 80);
defer session.deinit();
var parser = vt.Parser.init();
parser.feed(output_bytes, &session);
if (session.takeError()) |err| return err;
try session.drainReplies(writer);
const screen = session.activeScreen();
const modes = session.getModes();
const bytes = try vt.Input.encodeKey(buffer, event, modes);
```

The screen pointer addresses the active screen field; screen switches exchange
its contents and invalidate borrowed rows. `resize()` prepares both grids before
committing, preserves top-left overlap without reflow, and retains input modes.
RIS (`ESC c`) resets both screens, negotiated modes, and stacks. Reply draining
acknowledges bytes only after the writer succeeds; a writer that partially writes
before failing must not retry the whole queue without accounting for its progress.
The Linux adapter moves replies into its nonblocking PTY queue before draining.

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

Unicode segmentation data and its conformance fixture are pinned to 15.1.0.
Regenerate with `python3 tools/generate_unicode.py /path/to/UCD.zip`. Generated
tables and original test fonts are committed; builds perform no downloads.
`tools/generate_test_fonts.py` rebuilds the tiny MIT-licensed fonts using
FontTools 4.60.1. Bidi behavior uses the installed FriBidi Unicode implementation.

Protocol references: [Kitty keyboard](https://sw.kovidgoyal.net/kitty/keyboard-protocol/),
[xterm controls](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html),
[Unicode segmentation](https://www.unicode.org/reports/tr29/), and the installed
Wayland text-input-v3/primary-selection protocol XML files.
