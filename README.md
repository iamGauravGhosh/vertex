# Vertex

Vertex is a terminal emulator project written in Zig, with Linux as its primary
platform and Wayland as its main focus. It aims to deliver a highly customizable,
fast, and responsive terminal experience, with particular attention to Hyprland
and Niri users.

The project includes a reusable VT parser, a terminal screen model, and a
command-line event tracer.
The parser handles incremental UTF-8 text and ESC, CSI, OSC, DCS, and opt-in APC
sequences without allocating memory. OSC/APC streaming hooks allow future image
protocol consumers to process large transfers. The fixed-size screen model
applies text, ANSI 16/256/RGB colors and attributes, cursor movement, editing,
and scrolling regions to a grid of cells. Image decoding, windowing, rendering,
and shell/PTY integration are still future work. Running without arguments
prints the original startup message.

## Development goals

- **Linux and Wayland first:** Build a smooth terminal experience on Wayland,
  with particular attention to integration and usability on Hyprland and Niri.
- **Broader platform support:** Make Vertex available on other POSIX-based
  operating systems, including macOS, while keeping Linux the primary focus.
- **Extensive customization:** Give users control over appearance, keybindings,
  and terminal behavior so Vertex can adapt to their workflows.
- **Speed and responsiveness:** Aim for fast startup, high throughput, and
  minimal input and rendering latency, keeping interaction smooth even under
  heavy terminal output.

## Requirements

- Zig 0.17.0 (the toolchain used to create this scaffold).
- No external dependencies.
- Python 3 for the executable smoke checks in CI.

## Commands

```sh
zig test src/main.zig       # Run parser, screen, and CLI unit tests directly
zig fmt --check build.zig src tests
```

Build commands (reserved for CI by the inherited repository instructions):

```sh
zig build                  # Install the executable and Vertex's license
zig build test             # Run unit tests and the public-module consumer test
python3 tests/cli_smoke.py zig-out/bin/vertex
```

Once built, inspect a stream of terminal output:

```sh
printf '\033[31mHello\033[0m\n' | zig-out/bin/vertex parse
zig-out/bin/vertex --help
printf '\033_Ga=q;AAAA\033\\' | zig-out/bin/vertex parse --stream-strings
```

Example output begins with:

```text
CSI prefix="" params=[31] intermediates="" final="m"
PRINT U+0048 "H"
```

The trace escapes payload bytes and never sends incoming escape sequences to
your terminal. This command parses events; the reusable screen model applies
them to cells without drawing a window.
See the [parser API and integration guide](docs/vt-parser.md) for a Zig consumer,
event lifetimes, recovery behavior, and limits. The [screen model guide](docs/screen.md)
shows parser-to-screen integration and supported controls. The initial screen
uses fixed dimensions and one Unicode scalar per cell, without scrollback or
an alternate screen.

## Structure

```text
vertex/
├── build.zig              # Build, run, and unit-test steps
├── build.zig.zon          # Package metadata and dependencies
├── src/
│   ├── main.zig           # Application entry point
│   ├── cli.zig            # Stdin event-trace command
│   ├── terminal/
│   │   ├── root.zig       # Public parser and screen APIs
│   │   ├── Parser.zig     # Incremental VT and UTF-8 state machine
│   │   ├── Screen.zig     # Grid, styles, cursor, editing, and scrolling
│   │   ├── trace.zig      # Escaped event formatting
│   │   ├── parser_tests.zig
│   │   └── screen_tests.zig
│   ├── renderer/
│   │   └── root.zig       # Text and cursor rendering
│   └── platform/
│       └── root.zig       # OS, window events, PTY, and shell integration
├── assets/
│   └── fonts/             # Future font assets
├── docs/
│   ├── architecture.md    # Responsibilities and milestones
│   ├── vt-parser.md       # Parser API and behavior
│   └── screen.md          # Screen API and supported controls
├── tests/                 # Module-consumer and executable smoke checks
├── LICENSE                # Vertex's MIT license
└── .gitignore
```

See [the architecture notes](docs/architecture.md) for the initial direction.

Vertex uses the [MIT license](LICENSE). The parser has no external dependencies.
