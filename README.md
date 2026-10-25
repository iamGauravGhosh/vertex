# Vertex

Vertex is a terminal emulator project written in Zig, with Linux as its primary
platform and Wayland as its main focus. It aims to deliver a highly customizable,
fast, and responsive terminal experience, with particular attention to Hyprland
and Niri users.

The Linux MVP opens a native Wayland window, starts your interactive shell through
a PTY, and renders shaped text using OpenGL ES 3 through EGL, with automatic CPU
fallback. Glyph atlases and row damage tracking avoid repeated rasterization and
redrawing unchanged text. Keyboard input, colors, a cursor, window resizing, and
integer display scaling are supported.

The project also includes a reusable VT parser, a terminal screen model, and a
command-line event tracer.
The parser handles incremental UTF-8 text and ESC, CSI, OSC, DCS, and opt-in APC
sequences without allocating memory. OSC/APC streaming hooks allow future image
protocol consumers to process large transfers. The resizable screen model
applies text, ANSI 16/256/RGB colors and attributes, cursor movement, editing,
and scrolling regions to a grid of cells. Image decoding remains future work.

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

- Zig 0.17.0.
- Linux with a Wayland compositor for the GUI.
- `pkg-config`, `wayland-scanner`, `wayland-protocols`, and development libraries
  for Wayland/wayland-egl, xkbcommon, FreeType, Fontconfig, HarfBuzz, EGL,
  OpenGL ES 3, and libc/PTYs.
- An installed monospace font, resolved through Fontconfig.
- Python 3 and Weston for executable/window smoke checks in CI.

On Debian/Ubuntu, GUI development dependencies are `libwayland-dev`,
`wayland-protocols`, `libxkbcommon-dev`, `libfreetype-dev`, `libfontconfig1-dev`,
`libharfbuzz-dev`, `libegl1-mesa-dev`, `libgles2-mesa-dev`,
`libwayland-egl-backend-dev`, and `fonts-dejavu-core`. For software GPU tests,
install `libgl1-mesa-dri`. On Arch Linux, use `wayland`, `wayland-protocols`,
`libxkbcommon`, `freetype2`, `fontconfig`, `harfbuzz`, `libglvnd`, `mesa`, and a
monospace font.

The public terminal module and `-Dgui=false` executable remain dependency-free.

## Releases

CI runs on branch pushes, pull requests, and all pushed tags. Pushing a version
tag such as `v0.1.0` publishes a GitHub Release with generated notes after all
checks pass. Tags use `vMAJOR.MINOR.PATCH`, with optional SemVer prerelease and
build suffixes. A tag such as `v0.1.0-rc.1` creates a prerelease; unrelated or
malformed tags run checks without publishing.

To release a committed revision containing the release workflow:

```sh
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0
```

Creating a local tag alone does not trigger CI. An existing GitHub Release is
never overwritten; publish a new version tag for subsequent releases. No extra
repository secrets are needed.

Each release includes `vertex-<tag>-linux-x86_64.tar.gz` and its `.sha256` checksum.
The archive contains `vertex`, `README.md`, and `LICENSE` in a matching directory.
The executable is built with Zig 0.17.0 in ReleaseSafe mode for a baseline x86_64
CPU on Ubuntu 24.04. It needs a compatible Linux/glibc system, a Wayland compositor,
Wayland client/EGL libraries, xkbcommon, FreeType, Fontconfig, HarfBuzz, EGL,
OpenGL ES libraries, and a monospace font. EGL/GLES libraries are required even
when selecting CPU rendering; an available GPU driver is optional in auto mode.
On Ubuntu 24.04, install the runtime dependencies with:

```sh
sudo apt-get install libwayland-client0 libwayland-egl1 libxkbcommon0 libfreetype6 libfontconfig1 libharfbuzz0b libegl1 libgles2 libgl1-mesa-dri fonts-dejavu-core
```

After downloading both release files into the same directory:

```sh
sha256sum --check vertex-v0.1.0-linux-x86_64.tar.gz.sha256
tar -xzf vertex-v0.1.0-linux-x86_64.tar.gz
./vertex-v0.1.0-linux-x86_64/vertex
```

## Commands

```sh
zig test src/main.zig       # Run parser, screen, and CLI unit tests directly
zig fmt --check build.zig src tests
```

Build commands (reserved for CI by the inherited repository instructions):

```sh
zig build                  # Install the executable and Vertex's license
zig build test             # Core, public-module, and headless Linux integration tests
zig build -Dgui=false      # Parser-only executable, without GUI dependencies
python3 tests/cli_smoke.py zig-out/bin/vertex
python3 tests/wayland_smoke.py zig-out/bin/vertex  # Private headless Weston instances
```

Once built, launch the terminal or run an explicit command:

```sh
zig-out/bin/vertex
zig-out/bin/vertex -- /bin/sh -c 'printf "Hello\\n"; exec /bin/sh -i'
```

Set `VERTEX_RENDERER=auto|gpu|cpu` to choose the backend. The default `auto` tries
GPU rendering, then permanently switches to CPU for the session if graphics
initialization or rendering fails. `gpu` reports graphics failures directly;
`cpu` bypasses EGL initialization. For example: `VERTEX_RENDERER=cpu zig-out/bin/vertex`.

The default shell is `$SHELL`, then the account shell, then `/bin/sh`. Vertex
inherits the working directory and environment and sets `TERM=xterm-256color`
and `COLORTERM=truecolor`. Exiting the shell closes the window; the shell's exit
status becomes Vertex's status. A missing Wayland connection fails with a diagnostic.

To inspect a stream of terminal output without opening a window:

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
shows parser-to-screen integration and supported controls.

## MVP limits

The terminal targets basic shell work, including command editing, history,
completion, Ctrl shortcuts, and output scrolling. It starts at 80×24 cells unless
the compositor assigns another size. Fonts use 16 logical pixels; appearance is
currently fixed. Resizing preserves the top-left overlap without reflow and
notifies the PTY. There are no client-side decorations; use compositor shortcuts
for moving, resizing, and closing the window.

HarfBuzz shapes left-to-right runs and enables standard ligatures and contextual
substitutions when the chosen font supports them. Each Unicode scalar still
occupies one cell; ligatures retain the source cell span and cursor positions.
Wide characters, grapheme layout, bidirectional layout, font fallback, color emoji, IME,
scrollback history, alternate screens, application cursor/keypad modes, terminal
query replies, selection/clipboard, mouse reporting, images, and fractional-scale
protocols remain future work. Missing glyphs use a replacement glyph. Blink is
rendered steadily. `TERM=xterm-256color` does not imply full xterm compatibility;
full-screen programs such as Vim and htop are outside this milestone.

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
│   │   ├── root.zig       # Shared shaping, rasterization, and CPU reference drawing
│   │   ├── Atlas.zig      # Bounded alpha-mask pages
│   │   ├── Damage.zig     # Row and cursor presentation damage
│   │   └── Gpu.zig        # EGL/GLES3 rendering and presentation
│   └── platform/
│       ├── root.zig       # Optional Linux GUI entry
│       ├── linux.zig      # Wayland, keyboard, buffers, and event loop
│       ├── Pty.zig        # PTY and child-session lifecycle
│       ├── input.zig      # Terminal key encoding
│       └── c.h            # Build-time system-header bindings
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

See [the architecture notes](docs/architecture.md) for integration details.

Vertex uses the [MIT license](LICENSE). The parser has no external dependencies.
