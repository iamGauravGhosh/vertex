# Developer application compatibility

Vertex targets modern developer workflows on Linux/Wayland. Compatibility is
maintained through protocol tests, native CPU/GPU comparisons, and real
applications running through Vertex's PTY, parser, screen, replies and input
encoders. It is not a claim that every future application or xterm extension has
been implemented.

## Application checks

| Application | Test baseline | Workflow |
| --- | --- | --- |
| Neovim | 0.12.6 | Unicode paste, edit/save, resize and shell restoration |
| LazyVim | committed `tests/lazyvim/lazy-lock.json` | The same editing workflow, actual diagnostic undercurls, Snacks files/explorer |
| Vim / Emacs `-nw` | Ubuntu 24.04 distribution packages, recorded in CI artifacts | Edit/save, paste, resize and shell restoration |
| Helix | 25.07.1 | Edit/save with enhanced keyboard negotiation and resize |
| lazygit | 0.66.2 | Temporary repository, stage a real change, resize and quit |
| lazydocker | 0.25.2 | Disposable daemon/container, navigation and resize |
| Codex | 0.164.0 | Multiline input, local streamed Responses API, cancellation and exit |
| Claude Code | 2.1.300 | Multiline input, local streamed Messages API, cancellation and exit |
| OpenCode | 1.19.4 | Multiline input, local mock provider, cancellation and exit |
| Frameworks | locked fixtures | ncurses, Ink 8.0.0, Textual 8.2.8, Bubble Tea 1.3.10; Codex also exercises Ratatui/Crossterm |

The suite runs applications standalone and through tmux. Neovim also runs in
Zellij and Herdr. Neovim, Helix and lazygit repeat standalone/tmux checks through
an ephemeral localhost SSH server with temporary keys. This verifies the remote
terminal byte stream, rather than Internet latency or remote OS packaging.
Existing multiplexer splitting, detach/reattach, clipboard and stress checks
remain separate.

The fixtures isolate homes, repositories, configuration, sessions and sockets.
No personal agent credentials are read and model replies come from a loopback
HTTP server. The mock never requests tools. LazyVim's UI fixture disables update
checks and automatic grammar/tool installation and uses Lua fuzzy matching;
the committed plugin lock identifies the configuration it reproduces.

CI builds and runs `zig build test-tuis`; applications are test dependencies,
never Vertex runtime dependencies. The compatibility job gates releases. Weekly
runs check whether newer application releases need validation before updating
the committed pins. Distribution editor versions are saved with each run.

Failure artifacts include the outer grid, styles, graphemes, exit status and a
styled HTML grid reconstruction, plus a PTY trace capped at 32 MiB. The HTML is
diagnostic grid evidence, not a GPU screenshot. Native renderer tests separately
compare CPU/GPU pixels and incremental/full redraws.

## Everyday terminal behavior

- Wheel and Shift+PageUp/PageDown navigate main-screen history. Typing or pasting
  returns to live output. Output arriving while scrolled does not move the view,
  until the oldest retained rows are evicted.
- Drag selects text; double-click selects a whitespace-delimited word and
  triple-click selects a physical row. Ctrl+Shift+C copies; selection also
  publishes primary selection when the compositor supports it. Escape clears
  an active selection. Ctrl+Shift+V and Shift+Insert keep their paste roles.
- Application mouse tracking takes priority; Shift (or the configured reporting
  bypass) permits local selection/history. Alternate screens without tracking
  can use mode 1007 wheel-to-arrow behavior.
- Main-screen text and history rewrap on resize. Alternate screens stay on a
  fixed grid. Graphemes, hyperlinks and selections survive reflow; an evicted
  selection is cleared. `CSI 3 J` clears retained history.

The GUI defaults to 10,000 history rows or 64 MiB of retained row storage,
whichever is reached first. Limits, reflow and visual bell reload live:

```toml
[terminal]
scrollback_lines = 10000
scrollback_bytes = 67108864
reflow = true
visual_bell = 100 # milliseconds; 0 disables it
```

History keeps text, styles and links. Image pixels remain subject to the live
graphics budget and are not retained in history. Image placements keep their
cell coordinates and existing resize clipping; they do not reflow with text.
Disabling reflow retains fixed-grid clipping for applications that need it.

## Colors and editor capability detection

Vertex supports underline styles 0–5 (`SGR 4:n`), independent indexed/RGB
underline colors (`SGR 58`) and reset (`59`). `DECRQSS m` accurately reports
current styling, enabling Neovim's undercurl probe. XTGETTCAP also reports `Su`,
`Smulx`, `Setulc`, RGB, clipboard and synchronization capabilities.

OSC 4/10/11/12 set/query the palette, foreground, background and cursor color;
104/110/111/112 restore configured colors. Application overrides survive config
reload until explicitly reset. Renderer colors and query replies share the same
resolved session theme.

`TERM=xterm-256color` remains the portable default, with `COLORTERM=truecolor`,
`TERM_PROGRAM=vertex` and XTVERSION identifying Vertex honestly. Applications
which only inspect terminfo can opt into the included extended entry:

```sh
tic -x -o ~/.terminfo assets/vertex.terminfo
TERM=vertex-256color hx
```

Use the default TERM for SSH unless that entry is also installed remotely. A
modern tmux configuration should use `default-terminal "tmux-256color"`; its
outer terminal features can include `RGB`, `extkeys`, `clipboard`, `sync`,
`usstyle` and `cstyle` when the client supports them. Vertex never edits dotfiles.
Legacy Escape timing remains controlled by applications and multiplexers;
negotiated Kitty/extended keys avoid many legacy ambiguities.

Unicode tables and grapheme conformance data are pinned to final Unicode 18.0.
Mode 2027 is reported as permanently enabled, matching the engine's actual
grapheme behavior. Ambiguous-width characters remain one column. Applications
with older width tables or a multiplexer that discards a character can still
require an upstream fix; the outer PTY trace distinguishes that from a Vertex
rendering issue.

Full xterm emulation, image history/animation, fractional-scale protocols and
unsupported color-font formats remain outside this compatibility baseline.
