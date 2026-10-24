# Architecture

Vertex is a terminal emulator written in Zig. The Linux MVP connects a native
Wayland window, CPU renderer, and interactive shell PTY to the reusable VT parser
and resizable screen model. A separate stdin trace CLI remains available.

## Responsibilities

- `src/main.zig`: select a window session or headless CLI and report errors.
- `src/cli.zig`: window-launch selection, `vertex parse`, and command-line help.
- `src/terminal/`: allocation-free parsing and event tracing, plus an owned screen
  grid with colors, attributes, cursor state, editing, and scrolling regions.
  Resizing preserves the top-left overlap without reflow. Scrollback and alternate
  screens remain future milestones.
- `src/renderer/`: Fontconfig font selection, bounded FreeType glyph cache, and
  cell/style/cursor drawing into XRGB8888 memory.
- `src/platform/`: native Wayland globals, xdg-shell, shared-memory buffers,
  xkbcommon keyboard state, timer-based repeat, PTY, and child lifecycle.
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
and scrolling commands. The screen allocates at initialization and resize and
processes events without allocation. See [the parser guide](vt-parser.md) for syntax and
[the screen guide](screen.md) for command execution and ownership.

## Image extension boundary

APC, OSC, and DCS payload events provide transport for future Kitty, iTerm2, and
Sixel handlers. APC/OSC streaming is opt-in; DCS always streams after its header.
Large payloads need no whole-message buffer in the parser.

Image support will follow this path:

```text
Parser events -> protocol handler -> decoder -> image store/placements -> renderer
```

Handlers will recognize protocol headers, assemble transfers, decode base64,
apply budgets, and generate replies. Decoders will produce validated pixels;
the image store will own their memory and placement relative to terminal cells.
The renderer will upload and draw those pixels. No backend or decoder interface
is fixed before those components exist. A consumer must discard provisional
data when a transfer is interrupted, cancelled, or ends before completion.

## Linux integration

The executable uses system libraries through build-time translated headers.
`wayland-scanner` generates stable xdg-shell declarations and protocol metadata
in the build cache. Only generated protocol code is C; application logic is Zig.
`-Dgui=false` omits the GUI libraries and code generation entirely.

One loop dispatches Wayland events, reads bounded PTY batches, flushes queued
keyboard bytes, and handles keyboard-repeat timers. It follows Wayland's
prepare/read/cancel contract and enables writable polling when a flush would
block. Frames are scheduled only when terminal state or window size changes.
Two active shared-memory buffers are used; resize retires old buffers until
the compositor releases them. Output enter/leave and scale events determine the
integer buffer scale, independently of logical terminal dimensions.

The PTY child receives a new session and controlling terminal, reset signal
dispositions, inherited working directory, and terminal environment variables.
A close-on-exec error pipe reports launch failure before entering the event loop.
The parent reaps child exits even when descendants retain the slave. Closing
the window hangs up the foreground job and shell session, with bounded waiting
and forced termination of an unresponsive shell.

Headless tests cover parsing, screen resizing, key encoding, PTY I/O and lifecycle,
and in-memory rendering. CI also starts private headless Weston instances at
different geometries/scales. The optional `VERTEX_TEST_WAYLAND=1` integration
test opens a real window, renders a short command, and checks its exit status.
Full-screen applications, scrollback, grapheme layout, and images remain future work.
