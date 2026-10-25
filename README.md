# Vertex

Vertex is a terminal emulator project written in Zig, with Linux as its primary
platform and Wayland as its main focus. It aims to deliver a highly customizable,
fast, and responsive terminal experience, with particular attention to Hyprland
and Niri users.

The Linux MVP opens a native Wayland window, starts your interactive shell through
a PTY, and renders shaped text using OpenGL ES 3 through EGL, with automatic CPU
fallback. Glyph atlases and row damage tracking avoid repeated rasterization and
redrawing unchanged text. Keyboard input, colors, a cursor, window resizing, and
integer display scaling, Unicode graphemes, mouse reporting, bracketed paste,
and negotiated modern keyboard input are supported.

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
  OpenGL ES 3, FriBidi, and libc/PTYs.
- An installed monospace font, resolved through Fontconfig.
- Python 3 and Weston for executable/window smoke checks in CI.

On Debian/Ubuntu, GUI development dependencies are `libwayland-dev`,
`wayland-protocols`, `libxkbcommon-dev`, `libfreetype-dev`, `libfontconfig1-dev`,
`libharfbuzz-dev`, `libfribidi-dev`, `libegl1-mesa-dev`, `libgles2-mesa-dev`,
`libwayland-egl-backend-dev`, and `fonts-dejavu-core`. For software GPU tests,
install `libgl1-mesa-dri`. On Arch Linux, use `wayland`, `wayland-protocols`,
`libxkbcommon`, `freetype2`, `fontconfig`, `harfbuzz`, `fribidi`, `libglvnd`, `mesa`, and a
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
Wayland client/EGL libraries, xkbcommon, FreeType, Fontconfig, HarfBuzz, FriBidi, EGL,
OpenGL ES libraries, and a monospace font. EGL/GLES libraries are required even
when selecting CPU rendering; an available GPU driver is optional in auto mode.
On Ubuntu 24.04, install the runtime dependencies with:

```sh
sudo apt-get install libwayland-client0 libwayland-egl1 libxkbcommon0 libfreetype6 libfontconfig1 libharfbuzz0b libfribidi0 libegl1 libgles2 libgl1-mesa-dri fonts-dejavu-core
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

Unicode 15.1 extended graphemes retain combining marks and emoji sequences in
one cluster. Wide and emoji clusters occupy two columns; ambiguous characters
occupy one. Fontconfig supplies fallback faces. FreeType color bitmaps and
COLRv0 glyphs render in color in both backends; unsupported color-font formats
use monochrome/replacement fallback. Missing system fonts can still limit coverage.

Bidirectional rendering is opt-in: set `VERTEX_BIDI=auto` to resolve paragraphs
across soft wraps, or `VERTEX_BIDI=off` (the default) for fixed visual columns.
Wayland text-input-v3 supplies IME composition and a temporary preedit overlay.
Without that protocol, XKB dead-key/Compose input remains available. The PTY
application owns surrounding editable text, so IME surrounding-text deletion is
not advertised.

## Input and terminal protocols

- Mouse tracking supports X10 (9), normal (1000), button-motion (1002), and
  all-motion (1003), with legacy, SGR (1006), and SGR pixel (1016) encoding.
  Mode 1004 reports keyboard focus changes. Shift bypasses mouse reporting.
- Ctrl+Shift+V pastes the Wayland clipboard. Shift+Insert and middle-click
  paste primary selection when the compositor supports it. Middle-click goes
  to the application while mouse reporting is enabled; Shift overrides it.
- Mode 2004 wraps paste in bracketed-paste delimiters. Transfers are asynchronous,
  capped at 8 MiB, and queued only after successful receipt. Newlines become CR;
  NUL and ESC are removed. Input and replies never split a queued paste transaction.
- Kitty keyboard negotiation implements all five enhancement flags, queries,
  set/add/remove, and bounded push/pop stacks, independently on main and alternate
  screens. Legacy input remains the default. xterm modifyOtherKeys levels 0–2
  are used when Kitty enhancements are inactive.
- Main/alternate screen modes 47/1047/1048/1049, application cursor/keypad modes,
  basic device attributes, and status/cursor-position replies are supported.

Scrollback history, selection/copy UI, images, fractional-scale protocols, and
full xterm compatibility remain future work. Resizing preserves the top-left
intersection without reflow. Blink is rendered steadily. Color-font SVG and
COLRv1 painting are not supported.

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
│   │   ├── Session.zig    # Main/alternate screens, modes, and replies
│   │   ├── Input.zig      # Portable keyboard, pointer, and paste encodings
│   │   ├── Unicode.zig    # Grapheme boundaries and terminal widths
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
