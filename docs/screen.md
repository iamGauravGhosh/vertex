# Terminal screen model

`vertex_terminal.Screen` applies parser events to a resizable, owned grid. It
has no renderer, I/O, PTY, or shell dependencies. `Session` combines two screens
with negotiated input modes and a terminal reply queue; see [terminal protocols](terminal-protocols.md). The parser remains usable on
its own, and `vertex parse` continues to print syntax events rather than drawing
this grid.

## Usage and ownership

```zig
const std = @import("std");
const vt = @import("vertex_terminal");

fn example(allocator: std.mem.Allocator) !void {
    var screen = try vt.Screen.init(allocator, 24, 80);
    defer screen.deinit();
    var parser = vt.Parser.init();

    parser.feed("\x1b[31mHello\x1b[0m\r\n", &screen);
    // Feed further chunks to the same parser; chunk boundaries are arbitrary.
    // Only finish when the byte stream has actually ended.
    for (parser.finish()) |item| {
        if (item) |event| screen.handle(event);
    }

    const cell: vt.Cell = screen.getCell(0, 0).?;
    std.debug.assert(cell.codepoint == 'H');
    std.debug.assert(cell.style.foreground.indexed == 1);
    const cursor: vt.Cursor = screen.getCursor();
    std.debug.assert(cursor.row == 1 and cursor.column == 0);
}
```

The public API is:

| Call | Behavior |
| --- | --- |
| `Screen.init(allocator, rows, columns)` | Allocate and initialize a grid |
| `deinit()` | Free the grid; the value must no longer be used |
| `resize(rows, columns)` | Preserve top-left overlap, blank new cells, clamp cursors, reset margins; no reflow |
| `reset()` | Clear cells and restore initial state without reallocating |
| `apply(event)` | Consume an event, reporting allocation failures |
| `handle(event)` | Parser-handler adapter; latch errors until `takeError()` |
| `takeError()` | Retrieve and clear a latched error; subsequent events in the failed feed were skipped |
| `getGrapheme(row, column)` | Borrow a cluster’s scalars, or an empty slice for a continuation |
| `getCell(row, column)` | Return a cell by value, or null outside the grid |
| `getRow(row)` | Return a borrowed `[]const Cell`, or null outside the grid |
| `getCursor()` | Return cursor position and visibility by value |
| `getRowGeneration(row)` | Return a content generation, or null outside the grid |
| `getDamageRows()` | Borrow row flags accumulated since the last acknowledgment |
| `clearDamage()` | Acknowledge damage after successful presentation |
| `invalidateAll()` | Mark every row for repaint without changing cells |

Dimensions must be nonzero; overflowing the cell count or byte size returns
`error.InvalidDimensions`. Allocation failures return `error.OutOfMemory`.
ASCII writes and grid edits allocate nothing. Extending graphemes and storing
formatting controls can allocate; `apply()` reports failures, while `handle()`
latches them and skips later events until `takeError()`. Treat a failed feed as
interrupted. Resize deep-copies cluster storage; a failed resize leaves the
original grid and all state unchanged. A same-size
resize does nothing. Resize clears current/saved pending wrap and resets margins
to the whole screen; other styles and modes remain unchanged. Treat `rows`,
`columns`, backing storage, and other internal fields as read-only; use events
and `resize()` to update state. Do not
duplicate an owning `Screen` or mutate it concurrently.

Accessors and cursor coordinates are zero-based. Borrowed rows live until a
successful size-changing `resize()` or `deinit()`; events can change their
contents. Cells contain a `u21` visible base codepoint, a `Style`, width (1 or 2 on heads;
0 on continuations), and an immutable borrowed grapheme slice. Use `getGrapheme()`
for complete text, including combining marks and formatting controls. Cluster
slices can be invalidated by any event, resize, or deinit; cell copies do not
own their slices. Unicode 15.1 extended grapheme boundaries and widths replace
scalar-per-cell storage. Wide/emoji clusters occupy two columns, ambiguous-width
characters one. Leading combining marks display a dotted circle. A wide cluster
on a one-column screen displays a replacement. Blank cells contain a space. Initialization
and reset use default colors and no attributes; erasure, editing, and scrolling
fill spaces using the active style.

`Color` is a tagged union of `.default`, `.indexed: u8`, and
`.rgb: { r: u8, g: u8, b: u8 }`. Colors remain symbolic; palette lookup, default
colors, and visual effects such as inverse/blink belong to the renderer.
Bold does not implicitly change a color index.

## Presentation damage

Initialization, size-changing resize, reset, and `invalidateAll()` mark all rows.
Writes, erasure, insertion/deletion, and scrolling mark affected rows. Cursor
changes, SGR-only changes, and ignored events leave the row flags unchanged;
a renderer must compare the current cursor with its last presented cursor and
repaint the old/new visible cursor rows separately.

`getDamageRows()` returns a borrowed `[]const bool` valid until resize/deinit.
Flags accumulate until `clearDamage()`. One presentation consumer owns that
acknowledgment and must clear only after successfully presenting the latest
state, retaining flags while a frame or buffer is unavailable. Multiple rendering
consumers must coordinate their own acknowledgments. Direct mutation of backing
cells or other internal fields is unsupported and bypasses damage tracking.
Damage inspection and acknowledgment allocate nothing. A failed resize preserves
both the cells and pending damage; a same-size resize leaves damage unchanged.

## Supported controls

This limited contract is informed by the
[xterm control-sequence reference](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html);
it does not claim complete xterm compatibility. The parser recognizes seven-bit
ESC-prefixed sequences; its existing UTF-8 and recovery rules still apply.

| Input | Effect |
| --- | --- |
| Printable scalar | Overwrite the cell, then advance; wrap is delayed until the next scalar |
| BS, CR | Move left without erasing; move to the first column |
| HT | Move to the next tab stop (every eight columns by default), clamped at the right edge |
| LF, VT, FF; ESC `D` | Move down without changing column; scroll at the bottom margin |
| ESC `E`, ESC `M` | Next line at column zero; reverse index, scrolling at the top margin |
| CSI `A`, `B`, `C`, `D` | Relative cursor movement |
| CSI `E`, `F` | Relative vertical movement followed by column zero |
| CSI `G`, `d`, `H`, `f` | Absolute column, row, or row/column position |
| ESC `7`/`8`; CSI `s`/`u` | Save/restore one cursor snapshot; CSI `s` sets margins when mode 69 is enabled |
| CSI `J`, `K` | Erase display/line: cursor to end (0), start through cursor (1), or all (2) |
| CSI `X`, `@`, `P` | Erase, insert, or delete characters without crossing a row |
| CSI `L`, `M` | Insert/delete rows from the cursor through the bottom margin |
| CSI `S`, `T` | Scroll the region up/down without moving the cursor |
| CSI `top;bottom r` | Set vertical margins; omitted/zero values default to screen edges |
| CSI `?6h`/`?6l` | Enable/disable origin mode and home the cursor |
| CSI `?7h`/`?7l` | Enable/disable autowrap, clearing pending wrap |
| CSI `?25h`/`?25l` | Show/hide the cursor |
| ESC `c` | Reset all screen state |

Counts and positions default to one; zero also means one. Escape coordinates
and margins are one-based. Counts are clamped before moving memory. Absolute
positions normally address the entire screen. In origin mode they address and
are clamped to the scrolling region. Relative vertical movement stops at the
corresponding margin when approaching it from within the region; movement
outside that margin is bounded by the screen edge.

Margins default to the whole screen. Explicit regions require
`1 <= top < bottom <= rows`; invalid requests do nothing. Valid requests home
the cursor according to origin mode. A one-row screen always has its full row
as the default region. LF/index/reverse index scroll only at the appropriate
margin; scrolling preserves cells outside the region. Line insertion/deletion
does nothing outside the region and otherwise resets the column to zero.

Cursor movement and implemented editing/erasure/scroll commands clear pending
wrap. SGR, saving, visibility changes, and unsupported commands preserve it.
Disabling wrap causes printing at the last column to overwrite that cell.
Save/restore retains position, style, origin mode, autowrap, and pending wrap;
visibility remains independent. Restore clamps saved rows to the current
region when restoring origin mode.

DEC G0/G1 ASCII and special-graphics designation (`ESC (` / `ESC )` with `B` or
`0`), SI/SO, and saved charset state support legacy line drawing. ESC `H` sets
a tab stop; CSI 0/3 `g` clears the current/all stops; CSI `I`/`Z` move forward/back
through stops. Resize preserves existing stops and initializes new columns at
eight-column intervals. CSI `b` repeats the preceding printed scalar, with work
bounded to the cell count per command.

CSI `Ps SP q` selects block (0–2), underline (3–4), or bar (5–6) cursor shapes.
Blink variants render steadily. Cursor shape affects presentation damage without
invalidating shaped text.

Mode 69 enables horizontal margins, making CSI `left;right s` set the region
instead of saving the cursor. Disabling it restores full-width margins. Origin
addressing uses both margin pairs. Scrolling, line edits, and character insertion/
deletion within the region preserve adjacent panes. Graphemes straddling a region
boundary are erased as whole clusters before ownership moves. Resize resets both
margin pairs. The row content generations change on every affected write/edit,
even while damage remains pending. A unique read-only screen identity distinguishes
main/alternate screens, resized storage, and temporary IME overlays.

`Screen.reset()` does not reset the separate parser. To abandon a stream,
reset both objects; use `Parser.finish()` to finalize a stream normally.

## SGR colors and attributes

- Foreground `30–37`/`90–97`, background `40–47`/`100–107`, and default resets
  `39`/`49`.
- Indexed colors: `38;5;n` / `48;5;n` and colon equivalents.
- RGB: `38;2;r;g;b` / `48;2;r;g;b`, `38:2:r:g:b`, or
  `38:2:[colorspace]:r:g:b`, also with `48`. The optional colorspace must be
  empty or zero; channels and indexes must be present and in `0–255`.
- Bold (1), faint (2), italic (3), underline (4), blink (5/6), inverse (7),
  hidden (8), strikethrough (9). Resets are 22 (bold and faint), 23, 24, 25,
  27, 28, and 29 respectively. Blink stores a boolean, not a blink speed.
- Empty SGR, omitted top-level values, and 0 reset the entire style.

SGR only affects subsequent writes and blank fills. Unsupported attribute
subgroups such as `4:3` are ignored together. Invalid color groups retain the
previous color and consume their components, including missing values. For
semicolon colors, mode 5 consumes two following entries and mode 2 consumes
four; an unknown mode discards the rest of that SGR. Valid later top-level
attributes still apply after a group with known arity. Mixed colon/semicolon
components within a color are rejected.

Unimplemented sequences, unrelated private prefixes, intermediates, string
events, and C0 controls other than those listed above are ignored by `Screen`.
`Session` additionally handles input protocols and replies. Subparameters
outside SGR are ignored as a whole command. `Screen` generates no replies; use `Session` when replies are needed.

## Limits and validation

The model has no reflow, scrollback, or images. Alternate
screens are owned by `Session`. Screen storage stays in logical order; visual
bidi ordering and font selection belong to the renderer. The Linux application connects it to Wayland GPU/CPU renderers
and shell PTY; those dependencies are outside the public terminal module.

`zig test src/main.zig` covers ownership and allocation failure, controls,
styles, editing, scroll regions, degenerate sizes, split input, and arbitrary
byte streams. `tests/consumer.zig` also exercises the screen using only the
public module; existing CI runs it in Debug and ReleaseSafe.
