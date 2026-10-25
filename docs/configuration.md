# Configuring Vertex

Vertex reads **TOML** from `$XDG_CONFIG_HOME/vertex/config.toml`, or
`~/.config/vertex/config.toml` when XDG_CONFIG_HOME is unset or relative. A missing
default file uses built-in defaults. The old font-only `vertex/config` is no
longer read: move `font_family` to `[font] family`, and `font_size` to `[font] size`.
Strings must use TOML quotes.

```toml
[font]
family = "JetBrainsMono Nerd Font"
size = 13
ligatures = false

[window]
opacity = 0.88
unfocused_opacity = 0.8
dynamic_padding = true
[window.padding]
left = 12
right = 12
top = 10
bottom = 10

[cursor]
shape = "bar"
blinking = true
```

A font must contain ligature glyphs for `ligatures = true` to have an effect.
Nerd Fonts whose names contain `NL` normally omit ligatures. Required Arabic and
other complex-script shaping, combining marks, and emoji clusters continue to
work when optional ligatures are disabled.

## Commands and precedence

```sh
vertex config defaults                          # Print the complete default TOML
vertex config check                             # Check config and font options, no window
vertex config check --config ./rice.toml
vertex --config ./rice.toml
vertex --config ./rice.toml -- /bin/sh -l
```

`config check` is available in the GUI-enabled Linux executable and does not need
a Wayland connection. `config defaults` also works in the parser-only executable.
An explicitly requested missing file, invalid TOML, unknown option, invalid type
or out-of-range value fails startup before launching the child. Diagnostics show
the source filename, setting, and line/column where available.

Settings are applied in this order: built-in defaults, imports in their listed
order, the importing file, then environment overrides. Existing `VERTEX_FONT`,
`VERTEX_FONT_SIZE`, `VERTEX_RENDERER`, and `VERTEX_BIDI` overrides still work.
An empty VERTEX_FONT selects monospace; empty VERTEX_FONT_SIZE preserves the file's
size. The command following `--` overrides `terminal.shell`.

## Themes, imports, and reload

```toml
[general]
import = ["themes/dark.toml", "keys.toml"]
live_reload = true
```

Paths may be absolute, start with `~/`, or be relative to the importing file.
Tables merge by key; arrays replace the earlier array entirely. The importing
file overrides its imports. Missing imports and cycles are errors. Imports have
limits of 32 nested files, 128 file visits, and 1 MiB of total input per reload.
Copy the supplied [dark](../assets/themes/dark.toml) and
[light](../assets/themes/light.toml) themes to your config directory, then import
one. Omit local color overrides if you want the imported theme to supply them.

Vertex watches the main file and imports, including atomic editor saves and
initially missing directories. Changes are debounced by 120 ms. A candidate is
validated and its fonts/resources prepared before replacing active settings.
Invalid edits retain the previous settings and running shell. A `reload` key
binding also works when automatic reload is disabled.

Fonts, colors, spacing, padding, opacity, cursor settings, titles, bidi, mouse
settings and keybindings reload live. Shell, working directory, environment,
renderer backend, app ID, startup dimensions/mode and decorations affect new
windows; changing these prints a notice. Reload resets temporary font/opacity
adjustments made through shortcuts to the saved configuration. Reload does not
restart the PTY. Main-screen text/history reflow and history limits also reload
live; alternate screens retain fixed-grid resizing. See the
[compatibility guide](compatibility.md) for scrollback, copy and editor settings.

## Settings reference

The complete [annotated example](../assets/config.example.toml) is also installed
at `share/vertex/config.example.toml`. All sizes below are logical pixels unless
specified otherwise; integer display scaling applies automatically.

| Table | Settings and behavior |
| --- | --- |
| `font` | `family` (monospace), optional `bold_family`, `italic_family`, `bold_italic_family`; `size` (12 pt, 4–128 at 96 DPI); `ligatures` (false); `features` (array of HarfBuzz feature strings, e.g. `['ss01=1']`). Fontconfig patterns are accepted. |
| `font` | `cell_width_offset`, `cell_height_offset`, `glyph_offset_x`, `glyph_offset_y` (0, -256–256). Cell adjustments must leave positive dimensions. Glyph offsets are clipped to their assigned cells and do not move terminal columns. |
| `colors` | `foreground`, `background` (`'#RRGGBB'`); `normal` and `bright` (exactly eight colors in ANSI order); optional `cursor`, `cursor_text` (otherwise invert the cell); `dim_factor` (0.5, 0–1); `bold_is_bright` (false). |
| `colors.indexed` | Keys `'0'`–`'255'` override individual palette entries. Entries 16–255 otherwise use the xterm cube/grayscale; explicit indexed overrides also win over normal/bright arrays. |
| `window` | `opacity` (1, 0–1), optional `unfocused_opacity` (inherits opacity); only the default background and padding become transparent. Text, cursor, explicit application backgrounds and inline-image colors retain their own opacity. |
| `window.padding` | `left`, `right`, `top`, `bottom` (0, integers 0–8192). |
| `window` | `dynamic_padding` (false) centers leftover space around the grid after per-edge padding. Hit testing, IME, images, and mouse reports use this same content area. |
| `window` | `title` ('Vertex'), `dynamic_title` (true, allows application OSC 0/2 titles), `app_id` ('vertex', used by compositor rules). |
| `window` | `columns` (80), `rows` (24), 1–4096 with at most 1M initial cells; `startup_mode` ('windowed', 'maximized', 'fullscreen'). The compositor determines final geometry. |
| `window` | `decorations` ('none' or 'server'); requests server decorations through xdg-decoration where supported. Vertex does not draw a client title bar. |
| `cursor` | `shape` ('block', 'bar', 'underline'); `thickness` (2, 1–128); `blinking` (false); `blink_interval` (500 ms, 100–10000); `unfocused_hollow` (true, applies to block cursors). Applications can override cursor shape, visibility and blinking; CSI 0 SP q restores configured defaults. |
| `mouse` | `paste_button` ('middle'; 'none', 'left', 'middle', 'right'), `paste_primary` (true); `link_button` ('left'), `link_modifier` ('control'). Local paste yields to application mouse reporting unless bypass is held. |
| `mouse` | `reporting_bypass` ('shift'), `wheel_multiplier` (1, 0–100), `hide_when_typing` (false). Modifier choices: 'none', 'shift', 'control', 'alt', 'super'. Pointer hiding requires the optional Wayland cursor-shape protocol so the cursor can be restored. |
| `terminal` | `shell` (argument array; empty selects `$SHELL`, account shell, or `/bin/sh` with `-i`); optional `working_directory` (absolute, `~/`, or relative to the main config directory). |
| `terminal.env` | String environment additions/overrides for child processes. TERM defaults to xterm-256color and COLORTERM to truecolor. These may be overridden here; changing TERM does not change Vertex's implemented capabilities. |
| `terminal` | `bidi` ('off' or 'auto'); `renderer` ('auto', 'gpu', 'cpu'). Auto retains the existing permanent CPU fallback on graphics failure. |

## Keybindings

A supplied `keyboard.bindings` array replaces all defaults, including imported
bindings. Use XKB keysym names (`v`, `Insert`, `F5`, `equal`, `minus`). Modifier
names are case-insensitive and separated by `|`; supported names are Control,
Shift, Alt and Super. An omitted/empty `mods` means no modifiers. Caps/Num Lock do
not change matching. Duplicate shortcuts are errors.

```toml
[[keyboard.bindings]]
key = "v"
mods = "Control|Shift"
action = "paste"

[[keyboard.bindings]]
key = "equal"
mods = "Control"
action = "font_increase"

[[keyboard.bindings]]
key = "F5"
mods = "Control|Shift"
action = "reload"

[[keyboard.bindings]]
key = "F6"
action = "send_text"
text = "hello\n"

[[keyboard.bindings]]
key = "F7"
action = "launch"
command = ["/usr/bin/notify-send", "Vertex", "Custom shortcut"]
```

Actions: `paste`, `paste_primary`, `font_increase`, `font_decrease`, `font_reset`,
`opacity_increase`, `opacity_decrease`, `reload`, `fullscreen`, `new_window`,
`send_text` (requires `text`), and `launch` (requires `command`). Font steps are
one point; opacity steps are 0.05. Increase/decrease actions repeat while held.
`none` forwards the shortcut to the terminal application; `ignore` consumes it.
Local actions consume their key releases even if bindings change while held.
Commands use explicit argument vectors and are never implicitly evaluated by a
shell. `new_window` starts another Vertex with the same configuration path.

## Hyprland and Niri

Keep `window.app_id = 'vertex'` to use the provided examples. Use a separate
config and app ID for compositor rules targeting a floating terminal or another
profile. Vertex does not modify your compositor configuration.

- [Hyprland >= 0.55 Lua example](../assets/compositors/hyprland-0.55.lua), based on the [current window-rule documentation](https://wiki.hypr.land/Configuring/Basics/Window-Rules/).
- [Hyprland 0.54 hyprlang example](../assets/compositors/hyprland-0.54.conf), based on the [0.54 window rules](https://wiki.hypr.land/0.54.0/Configuring/Window-Rules/).
- [Niri >= 26.04 example](../assets/compositors/niri-26.04.kdl), based on [Niri window rules](https://niri-wm.github.io/niri/Configuration:-Window-Rules.html). Older versions must omit unsupported effects.

Set transparency in Vertex to keep text opaque. Compositor-wide window opacity
also fades text and images. Blur, borders, corner radii, shadows, gaps and
placement are compositor settings; enable and tune them there. Vertex does not
request native blur. Fractional-scale protocols, background images and tabs/panes
remain outside the configuration system's responsibilities;
multiplexers remain the source of tabs and panes.
