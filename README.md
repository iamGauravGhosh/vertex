# Vertex

Vertex is a terminal emulator project written in Zig, with Linux as its primary
platform and Wayland as its main focus. It aims to deliver a highly customizable,
fast, and responsive terminal experience, with particular attention to Hyprland
and Niri users.

The project is currently at the initial scaffold stage. Running it prints a
startup message. The terminal, renderer, and platform modules are placeholders
for future implementation; the goals below are not implemented yet.

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
- No external dependencies yet.

## Commands

```sh
zig build                  # Build into zig-out/bin/vertex
zig build run              # Run the starter executable
zig build test             # Run unit tests once test blocks are added
zig fmt build.zig src      # Format Zig source files
```

The test step is prepared for unit tests reachable from `src/main.zig`; no tests
are included yet. The `tests/` directory is reserved for future integration tests
and is not wired into the build.

## Structure

```text
vertex/
├── build.zig              # Build, run, and unit-test steps
├── build.zig.zon          # Package metadata and dependencies
├── src/
│   ├── main.zig           # Application entry point
│   ├── terminal/
│   │   └── root.zig       # Terminal state and escape-sequence parsing
│   ├── renderer/
│   │   └── root.zig       # Text and cursor rendering
│   └── platform/
│       └── root.zig       # OS, window events, PTY, and shell integration
├── assets/
│   └── fonts/             # Future font assets
├── docs/
│   └── architecture.md    # Responsibilities and first milestones
├── tests/                 # Future integration tests and fixtures
└── .gitignore
```

See [the architecture notes](docs/architecture.md) for the initial direction.
