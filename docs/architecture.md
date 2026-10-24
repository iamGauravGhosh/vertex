# Architecture

Vertex is a terminal emulator written in Zig. This initial scaffold only prints
a startup message; windowing, rendering, and shell integration are future work.

## Responsibilities

- `src/main.zig`: application entry point; eventually wire up the event loop.
- `src/terminal/`: terminal state, screen buffer, cursor, scrollback, and parser.
- `src/renderer/`: translate terminal state into drawn glyphs and a cursor.
- `src/platform/`: OS integration, window events, PTY, and shell lifecycle.
- `assets/fonts/`: font assets, once selected and licensed for redistribution.
- `tests/`: future integration tests and fixtures.

## Intended data flow

```text
Keyboard input -> PTY -> shell
Shell output -> PTY -> terminal parser -> screen state -> renderer
```

Keep the terminal model independent of the rendering backend and OS APIs so its
behavior can be tested without opening a window or launching a shell.

## First milestones

1. Choose the first supported OS, windowing library, and rendering backend.
2. Open a window and draw a fixed grid of text.
3. Start a shell through a PTY and read its output.
4. Add screen state and basic escape-sequence handling.
5. Connect keyboard input and propagate window-size changes to the PTY.
