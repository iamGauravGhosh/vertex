# Installing Vertex on Arch Linux

This guide installs the executable system-wide at `/usr/local/bin/vertex`, then
adds an app launcher entry and configuration for your user account. Vertex needs
an existing Wayland desktop, such as Hyprland or Niri. Its GUI currently requires
Linux and Wayland.

Choose a [source build](#build-and-install-from-source) or an available
[release download](#install-a-release-download), then continue with
[launching Vertex](#launch-vertex), the [app launcher](#add-an-app-launcher-entry),
and [configuration](#configure-vertex). If you already built Vertex, skip to
[install the built executable](#install-the-built-executable).

## Install runtime dependencies

Run this for either installation method:

```sh
sudo pacman -Syu --needed \
  wayland libxkbcommon freetype2 fontconfig harfbuzz fribidi \
  libglvnd mesa ttf-dejavu xdg-utils desktop-file-utils
```

This supplies the runtime libraries, a monospace font, `xdg-open` for links, and
the tools used below to validate and register the launcher entry. Keep the GPU
driver appropriate for your hardware installed as part of your Wayland setup.
EGL/GLES libraries are required even when using Vertex's CPU renderer.

`-Syu` also upgrades your system. Arch supports
[full system upgrades](https://wiki.archlinux.org/title/System_maintenance#Partial_upgrades_are_unsupported).

## Build and install from source

### Install build tools

```sh
sudo pacman -Syu --needed base-devel git pkgconf wayland-protocols zig
zig version
```

This revision requires **Zig 0.17.0**. Check the output before building: Arch's
rolling `zig` package can change independently of Vertex. If it supplies another
version, get the matching toolchain from the
[official Zig downloads](https://ziglang.org/download/) and put its directory
first in your `PATH`, then check `zig version` again. The `wayland` package from
the runtime step also supplies `wayland-scanner`.

### Download and build

```sh
git clone https://github.com/iamGauravGhosh/vertex.git
cd vertex
zig build -Doptimize=ReleaseSafe
```

The executable is `zig-out/bin/vertex`. Run it directly from your Wayland desktop
to try it before installation:

```sh
./zig-out/bin/vertex
```

Exit that shell to close the test window.

### Install the built executable

Run these commands from the repository root. This also works if you already
have a GUI-enabled `zig-out/bin/vertex` built for your system:

```sh
sudo install -Dm755 zig-out/bin/vertex /usr/local/bin/vertex
sudo install -Dm644 LICENSE /usr/local/share/licenses/vertex/LICENSE
sudo install -Dm644 vendor/stb/LICENSE /usr/local/share/licenses/vertex/stb_image-LICENSE
sudo install -Dm644 vendor/tomlc17/LICENSE /usr/local/share/licenses/vertex/tomlc17-LICENSE
```

`install -D` creates missing destination directories. Mode `755` makes the
executable runnable by all users, while `644` makes the license files readable.
Installing again replaces the installed copies and preserves your source tree.

Continue with [launching Vertex](#launch-vertex).

## Install a release download

Use this route when the
[GitHub Releases page](https://github.com/iamGauravGhosh/vertex/releases) has a
Linux download for the version you want. The release workflow packages
**x86_64** binaries; check your architecture with `uname -m`. Use a source build
on other architectures. Release binaries require compatible glibc and the
runtime dependencies listed above; Zig and the build tools are unnecessary for
this route.

Download both `vertex-<tag>-linux-x86_64.tar.gz` and its matching `.sha256` file
from the same release. In the download directory, set the tag to that release's
actual version, including the leading `v`. `vX.Y.Z` below is a placeholder:

```sh
VERTEX_TAG='vX.Y.Z'
VERTEX_PACKAGE="vertex-${VERTEX_TAG}-linux-x86_64"
sha256sum --check "${VERTEX_PACKAGE}.tar.gz.sha256"
```

Continue only when the checksum reports `OK`:

```sh
tar -xzf "${VERTEX_PACKAGE}.tar.gz"
cd "$VERTEX_PACKAGE"
sudo install -Dm755 vertex /usr/local/bin/vertex
sudo install -Dm644 LICENSE /usr/local/share/licenses/vertex/LICENSE
sudo install -Dm644 stb_image-LICENSE /usr/local/share/licenses/vertex/stb_image-LICENSE
sudo install -Dm644 tomlc17-LICENSE /usr/local/share/licenses/vertex/tomlc17-LICENSE
```

If no suitable release download is available, follow the source instructions.

## Launch Vertex

From a terminal in your Wayland desktop:

```sh
command -v vertex
vertex --help
vertex config check
vertex
```

`command -v vertex` should show `/usr/local/bin/vertex`. Vertex starts your
interactive shell and inherits the working directory. To run an explicit command,
put it after `--`, for example `vertex -- /bin/sh -l`.

## Add an app launcher entry

Copying an executable into `/usr/local/bin` makes it available to your shell.
Desktop launchers such as Rofi's application mode discover `.desktop` entries.
Create one for your account, without `sudo`:

```sh
vertex_applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$vertex_applications"
cat > "$vertex_applications/vertex.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Vertex
GenericName=Terminal Emulator
Comment=Wayland terminal emulator
Exec=/usr/local/bin/vertex
TryExec=/usr/local/bin/vertex
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
Keywords=terminal;shell;console;command;vertex;
StartupNotify=true
StartupWMClass=vertex
EOF
desktop-file-validate "$vertex_applications/vertex.desktop"
update-desktop-database "$vertex_applications"
```

`desktop-file-validate` should finish without diagnostics. Close and reopen your
app launcher, then search for **Vertex**. `Terminal=false` launches Vertex as a
GUI application. The filename `vertex.desktop` matches its default Wayland app ID,
`vertex`; keep them in sync if you customize `window.app_id`.
`Icon=utilities-terminal` uses the generic terminal icon from your installed icon
theme; its appearance depends on that theme.

If Rofi still shows a cached application list, rebuild its desktop cache:

```sh
rofi -show drun -drun-reload-desktop-cache
```

## Configure Vertex

Vertex reads `${XDG_CONFIG_HOME}/vertex/config.toml`, or
`~/.config/vertex/config.toml` when `XDG_CONFIG_HOME` is unset or relative. Create
the directory for your configuration. For the default location:

```sh
mkdir -p ~/.config/vertex
```

Save the following as `~/.config/vertex/config.toml`. If you already have that
file, back it up and merge these settings into its existing tables:

```toml
[general]
live_reload = true

[font]
family = "monospace"
size = 13.0
ligatures = false

[window]
app_id = "vertex"
opacity = 0.9
unfocused_opacity = 0.8
dynamic_padding = true

[window.padding]
left = 8
right = 8
top = 8
bottom = 8

[cursor]
shape = "block"
blinking = true
```

If you use an absolute `XDG_CONFIG_HOME`, create and edit
`$XDG_CONFIG_HOME/vertex/config.toml` instead. The old font-only
`~/.config/vertex/config` file is no longer read. Move `font_family` to
`[font] family` and `font_size` to `[font] size`, using TOML quotes for font names.

For a Nerd Font with terminal icons, optionally install
[JetBrains Mono Nerd Font](https://archlinux.org/packages/extra/any/ttf-jetbrains-mono-nerd/):

```sh
sudo pacman -Syu --needed ttf-jetbrains-mono-nerd
fc-match 'JetBrainsMonoNL Nerd Font'
```

Then change the existing `[font]` table's `family` to
`"JetBrainsMonoNL Nerd Font"`. Use `fc-list : family` to inspect installed names.

Validate your configuration:

```sh
vertex config check
```

Appearance settings reload while Vertex is running; an invalid edit keeps the
previous settings active. Run `vertex config defaults` to see the complete
annotated defaults. See the [configuration reference](configuration.md),
[example configuration](../assets/config.example.toml), and
[themes](../assets/themes) for colors, imports, and other options.

## Integrate with Hyprland

Check your version with `hyprctl version`. These examples use the Lua
configuration supported by Hyprland 0.55 and later. For Hyprland 0.54, use the
[hyprlang example](../assets/compositors/hyprland-0.54.conf) and its versioned
documentation instead.

### Terminal shortcuts

Find the Lua file that already defines your terminal shortcuts, commonly
`~/.config/hypr/hyprland.lua` or a module it loads, such as
`configs/keybinds.lua`. Back up every file you edit. Replace the existing terminal
bindings to avoid conflicts with shortcuts that still launch Kitty.

Define the variable in the **same Lua file as the bindings**: a `local terminal`
in another file is not shared with a module loaded using `require`.

```lua
local terminal = "/usr/local/bin/vertex"

hl.bind("SUPER + Return", hl.dsp.exec_cmd(terminal))
hl.bind("SUPER + SHIFT + Return", hl.dsp.exec_cmd(terminal, {
    float = true,
    size = "800 550",
}))
```

Super+Enter opens a normal terminal. Super+Shift+Enter opens a floating 800×550
terminal. These use Hyprland's
[Lua command and rule API](https://wiki.hypr.land/Configuring/Basics/Dispatchers/).
Keep other application bindings as needed; running an application in Vertex uses
`terminal .. " -- application"` as the command.

### Transparency and blur

Keep `window.app_id = "vertex"` in Vertex's TOML. Borders, gaps, rounding, and
animations inherit your existing compositor settings. To let Vertex apply the
background opacity configured above while keeping text and images opaque, add
this rule to your active Lua window-rules file, after any broader opacity rules:

```lua
hl.window_rule({
    name = "vertex-opacity",
    match = { class = "^vertex$" },
    opacity = "1.0 override 1.0 override",
    no_blur = false,
})
```

Global blur must also be enabled. If needed, merge these settings into your
existing decoration configuration:

```lua
hl.config({
    decoration = {
        blur = { enabled = true, size = 5, passes = 3 },
    },
})
```

More compositor effects are shown in the
[Hyprland Lua example](../assets/compositors/hyprland-0.55.lua).

### Apply and check

```sh
hyprctl reload
hyprctl configerrors
```

Fix any reported errors before continuing. Open a new Vertex window with each
terminal shortcut and check the floating window's size and appearance. Opening
Vertex from the application launcher should work too. A logout is unnecessary.

## Update

For a source installation, run `git pull --ff-only` from your checkout, check the
updated compiler requirements, then repeat the build and installation commands.
For a release installation, download and verify the new archive, then repeat its
installation commands. Close and reopen Vertex to use the updated executable.
Your per-user TOML and launcher entry remain in place.

## Uninstall

Undo the Hyprland bindings and rules you added, restoring your previous terminal
command, then reload Hyprland and check `hyprctl configerrors`.

Remove the executable, license files, and per-user launcher entry:

```sh
sudo rm -f /usr/local/bin/vertex \
  /usr/local/share/licenses/vertex/LICENSE \
  /usr/local/share/licenses/vertex/stb_image-LICENSE \
  /usr/local/share/licenses/vertex/tomlc17-LICENSE
vertex_applications="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
rm -f "$vertex_applications/vertex.desktop"
update-desktop-database "$vertex_applications"
```

These commands preserve your personal Vertex configuration and source checkout.

## Troubleshooting

- **`vertex: command not found`:** Try `/usr/local/bin/vertex --help`. If that
  works, ensure `/usr/local/bin` is in your shell's `PATH`. If the file is absent,
  repeat the appropriate executable installation step.
- **Missing from the app launcher:** Complete the desktop-entry step, check its
  `Exec` and `TryExec` paths, and reopen the launcher. For Rofi, use the cache
  reload command above. The entry must be created for your user, without `sudo`.
- **Wrong font or missing icons:** Check `fc-match` and `fc-list : family`, install
  the desired font, and verify the TOML family name. Fontconfig may substitute an
  unavailable family. Nerd Font glyphs and the launcher's theme icon are separate.
- **No Wayland connection:** Launch from an active Wayland desktop as your normal
  user. Vertex needs that session's Wayland connection and runtime directory.
- **Missing shared libraries:** Inspect `ldd /usr/local/bin/vertex` and complete
  the runtime dependency step. After library upgrades, a source build may need
  rebuilding against the updated system.
- **Graphics initialization failures:** Try `VERTEX_RENDERER=cpu vertex` to test
  CPU rendering, then check your graphics driver. The default `auto` renderer
  already falls back to CPU on graphics failures; EGL/GLES libraries are still
  required at program startup.
