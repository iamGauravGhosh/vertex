# Architecture

Vertex is a terminal emulator written in Zig. The VT parser, optional control
string streaming, fixed-size screen model, and stdin trace CLI are implemented.
Image decoding, windowing, rendering, and shell integration are future work.

## Responsibilities

- `src/main.zig`: process arguments and standard I/O; eventually the event loop.
- `src/cli.zig`: `vertex parse` and command-line help.
- `src/terminal/`: allocation-free parsing and event tracing, plus an owned screen
  grid with colors, attributes, cursor state, editing, and scrolling regions.
  Scrollback, resizing, and alternate screens remain future milestones.
- `src/renderer/`: translate terminal state into drawn glyphs and a cursor.
- `src/platform/`: OS integration, window events, PTY, and shell lifecycle.
- `assets/fonts/`: font assets, once selected and licensed for redistribution.
- `tests/`: public-module consumer and executable smoke checks.

## Intended data flow

```text
Keyboard input -> PTY -> shell
Shell output -> PTY -> terminal parser -> screen state -> renderer
```

Keep the terminal model independent of the rendering backend and OS APIs so its
behavior can be tested without opening a window or launching a shell.

The parser and screen model are exported as the `vertex_terminal` Zig module.
The parser accepts byte chunks and emits syntax events; it does not set terminal
modes, perform screen updates, write responses, or access the clipboard.
`Screen.handle` consumes those events and applies supported text, style, cursor,
and scrolling commands. The screen allocates its grid once and processes events
without further allocation. See [the parser guide](vt-parser.md) for syntax and
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

## First milestones

1. Choose the first supported OS, windowing library, and rendering backend.
2. Open a window and draw a fixed grid of text.
3. Start a shell through a PTY and read its output.
4. Connect the existing parser and screen model to the renderer and PTY output.
5. Connect keyboard input and propagate window-size changes to the PTY.
