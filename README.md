# Vertex

A terminal emulator project written in Zig, currently at the initial scaffold
stage. Running it prints a startup message. The terminal, renderer, and platform
modules are placeholders for future implementation.

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
