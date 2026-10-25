# Standalone and multiplexer workflows

Vertex starts the configured interactive shell by default. It works without any
multiplexer installed. Explicit commands also run directly:

```sh
vertex
vertex -- /bin/sh -c 'printf "Hello\n"'
vertex -- tmux
vertex -- zellij
vertex -- herdr
```

Tabs, split panes, workspace layouts, and persistent sessions come from the
multiplexer you choose. Terminal rendering, keyboard/mouse protocols, resizing,
and clipboard integration are Vertex features in both workflows. There is no
automatic multiplexer selection, installation, or startup dependency.

## Local and SSH use

Vertex supplies `TERM=xterm-256color` and `COLORTERM=truecolor`. Keep the
multiplexer's own terminal setting inside its panes (`tmux-256color` when
available for tmux). On remote machines, use a UTF-8 locale and an installed
terminfo entry for the selected inner terminal.

For tmux 3.2 or newer, these optional settings enable the features exercised by
the compatibility suite. Apply them only to terminal clients with these features;
other terminals may also identify themselves as `xterm-256color`.

```tmux
set -g mouse on
set -g extended-keys on
set -g set-clipboard on
set -as terminal-features ',xterm-256color:RGB:extkeys:clipboard:sync:margins:cstyle:focus'
```

Vertex never edits dotfiles. Zellij and Herdr use their normal configuration and
bindings. SSH carries the same terminal byte stream; no Vertex installation or
custom Vertex terminfo is required on the remote machine. Multiplexer and network
delays remain separate from Vertex's input handling.

Copy commands that emit OSC 52 can update the desktop clipboard, locally or over
SSH. Vertex accepts clipboard writes up to 8 MiB and never answers clipboard-read
requests. The Wayland compositor requires focus and a valid input serial; a copy
requested before the first key/button event waits for one. Native text selection
and main-screen scrollback/reflow are available as described in the
[compatibility guide](compatibility.md); multiplexer copy mode and history
remain available through the multiplexer.

## Compatibility checks

The test-only host uses Vertex's real PTY, parser, screen model, input encoders,
and replies. It accepts JSON control requests and exposes snapshots of the outer
terminal grid. It does not use multiplexer pane captures as a substitute for
terminal emulation. Optional traces record the actual PTY bytes.

CI pins tmux 3.8 source, Zellij 0.45.1 (no-web), and Herdr 0.9.5 with SHA-256
checksums in `tools/install_test_multiplexers.py`. These are test dependencies;
the executable and release packages do not bundle or require them.

The suite covers standalone operation, Unicode and RGB output, resized PTYs,
keyboard input, paste, splitting, detach/reattach, tmux mouse focus and clipboard
writes, and nested tmux/Zellij. It repeats these workflows through a temporary
localhost-only SSH server with temporary keys. The local tmux stress case keeps
input working beside 7 and then 31 concurrent log producers. All fixtures use
isolated sockets, sessions, and configuration paths.

Zellij 0.45.1 omits the combining accent in the suite's `e` + U+0301 sample from
its own outer output. The fixture records this upstream limitation. It still
requires the accent to survive whenever the actual PTY trace contains it;
standalone and tmux require the complete grapheme. CJK widths and box drawing
remain required in every case.

CI runs these commands (build commands remain CI-only under repository rules):

```sh
python3 tools/install_test_multiplexers.py /tmp/vertex-test-tools --build-tmux
# Add that test directory to PATH for the following CI steps.
zig build test-multiplexers -Doptimize=ReleaseSafe
VERTEX_BENCH=1 zig build test -Doptimize=ReleaseSafe
```

## Performance measurements

PTY output yields after 256 KiB or 2 ms, checked between at most 4 KiB slices.
Queued input is flushed before bulk output and between slices. Synchronization
mode 2026 holds presentation for at most 150 ms while input and parsing continue.
Rendering reuses row generations, font lookups, shaping/bidi scratch storage,
glyph metrics, and bounded atlas pages; same-color backgrounds are batched.

`VERTEX_BENCH=1` enables diagnostic benchmarks in the native test suite. One
updates eight rows of a 160×48 screen using DejaVu Sans Mono at 16 logical pixels,
warms 20 iterations, and reports p50/p95/p99 for 200 CPU redraws. On an Intel
i5-13500HX with Zig 0.17.0 ReleaseSafe, the pre-change p95 was approximately
416 µs; a post-change run measured approximately 306 µs. These are synthetic,
headless measurements, with no display refresh interval involved.

A second benchmark runs the real Wayland keyboard callback and writes to a PTY
while a child continuously produces output. It verifies that bytes were queued
and written and reports handler-to-write timing separately. Neither benchmark
includes compositor scheduling, physical display latency, application processing,
or SSH/network latency. Shared CI reports timings rather than enforcing unstable
wall-clock gates. Reference-workstation goals remain p95 ≤4 ms / p99 ≤8 ms for
handler-to-PTY work and p95 redraw work below one display refresh interval.

Native GPU/CPU pixel comparisons, deferred damage, cursor-only caching, OSC 52
limits/cancellation, slow clipboard recipients, and byte-split protocol recovery
are covered separately by the Zig tests. Full Wayland window checks run in CI
under private Weston instances.
