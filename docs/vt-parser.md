# Vertex parser contract

The parser converts byte streams into syntax events. It needs neither an
allocator nor a terminal window. Command execution, terminal state, replies,
image decoding, and rendering belong to consumers. The provided
[`Screen` consumer](screen.md) applies supported commands to a resizable grid;
the parser retains the syntax-only interface described here.

## Implementation basis

This replacement implementation and its parser tests were written for the
behavior specified here. Its internal design separates a scalar UTF-8 decoder,
command-header parsing, and control-string delivery. It does not vendor another
terminal's implementation, transition tables, or tests. This records the method
used for the replacement; it is not a formal clean-room certification.

The references below supply protocol facts. Their source code, prose, diagrams,
and example programs are not included in Vertex:

- [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/):
  control introducers and header byte classes.
- [Unicode UTF-8](https://www.unicode.org/versions/latest/core-spec/chapter-3/):
  scalar encoding and invalid-subsequence replacement.
- [Kitty graphics](https://sw.kovidgoyal.net/kitty/graphics-protocol/): APC framing.
- [iTerm2 images](https://iterm2.com/documentation-images.html): OSC image transfer.
- [DEC graphics manual](https://vt100.net/docs/vt3xx-gp/chapter14.html): Sixel DCS.

Error recovery and capacity choices below are Vertex's contract, rather than a
claim of complete protocol or terminal compatibility. Vertex's original code
remains covered by its MIT license.

## Module and calls

The build exports `vertex_terminal`. A consuming Zig package declares Vertex as
a dependency and imports that module into its own build:

```zig
const vertex = b.dependency("vertex", .{ .target = target, .optimize = optimize });
app.root_module.addImport("vertex_terminal", vertex.module("vertex_terminal"));
```

Within source, use `const vt = @import("vertex_terminal");`. The public API is:

| Call | Effect |
| --- | --- |
| `Parser.init()` | Buffered OSC, ignored APC, streamed DCS |
| `Parser.initWithOptions(options)` | Choose OSC/APC delivery modes |
| `next(byte)` | Return an ordered `[3]?Event`, with null trailing slots |
| `feed(bytes, &handler)` | Call `handler.handle(event) void` synchronously |
| `finish()` | Report incomplete UTF-8/open streams and reset input state |
| `reset()` | Abandon input silently |

Empty chunks do nothing. A chunk boundary does not end a command or scalar.
Both reset operations retain options; repeated `finish()` calls emit nothing.
Use `next` when delivering events involves fallible work such as writing output.

All slices in events borrow parser storage and expire at the next parser call.
Consume/copy them before returning from a handler. Do not reenter or share one
parser concurrently; independent instances do not share storage.

## Events

| Event | Contents |
| --- | --- |
| `print` | Unicode scalar (`u21`) |
| `execute` | C0 byte |
| `esc` | Intermediate bytes and final byte |
| `csi` | `Sequence` header |
| `osc` | Buffered payload and BEL/ST terminator; default OSC mode only |
| `dcs_begin`, `dcs_data`, `dcs_end` | Header, individual payload bytes, ending |
| `osc_begin`, `osc_data`, `osc_end` | Streamed OSC lifecycle; streaming mode only |
| `apc_begin`, `apc_data`, `apc_end` | Streamed APC lifecycle; streaming mode only |

`Sequence` includes a nullable private prefix, parameter slice, intermediate
slice, and final byte. Each `Parameter` has a nullable `u16` value and a preceding
separator (`none`, `semicolon`, or `colon`). An empty parameter list differs from
an omitted value, and omission differs from zero. Consumers interpret defaults.
For instance, `CSI 4:;0 m` retains `[4, null, 0]` and its `:`/`;` separators.

`StringEnd` is `st`, `cancelled`, `interrupted`, or `end_of_input`. `OscEnd`
additionally has `bel`. Streamed OSC never also emits the buffered `osc` event.
Begin is emitted at the string introducer (DCS begins after its valid header).
A streamed string ends exactly once, except when explicitly abandoned by reset.

## Byte handling and recovery

- Text uses UTF-8. Invalid leading bytes and maximal invalid prefixes produce
  U+FFFD. A byte that cannot continue a scalar is retried as new input. EOF
  replaces a pending incomplete scalar once.
- Only seven-bit ESC-prefixed control introducers are recognized. Raw C1 bytes
  are invalid text bytes; UTF-8 encoded C1 scalar values are ordinary `print`
  events. High bytes in command headers are ignored.
- Headers accept parameters in `0x30..0x3F`, then intermediates in `0x20..0x2F`,
  then a final in `0x40..0x7E`. ESC commands permit finals in `0x30..0x7E`.
  At most one private prefix in `0x3C..0x3F` may precede the numeric parameters.
- Ordinary C0 controls execute in ESC/CSI without ending the command. They are
  ignored in DCS headers. DEL is ignored in text and headers.
- OSC ends with BEL or ST (`ESC` followed by backslash). Other C0 bytes are
  ignored. Bytes at or above `0x20`, including DEL, are delivered unchanged.
- DCS/APC end with ST. DCS preserves payload bytes except DEL; APC preserves
  payload bytes including DEL and ordinary C0. Neither decodes payload UTF-8.
- CAN/SUB cancel an active command. A streamed payload emits `cancelled` before
  the `execute` event. Buffered OSC is discarded.
- ESC in a payload is held pending the next byte. Backslash completes ST;
  otherwise the string ends as `interrupted` and the following byte is handled
  as part of the new ESC command. A repeated ESC starts another escape.
- SOS, PM, and default-mode APC payloads are discarded through ST, interruption,
  or cancellation. Their bytes never become printable text.
- Invalid CSI is discarded through its final; invalid DCS through its payload's
  termination. ESC and CAN/SUB still recover from those discard paths.
- EOF discards unfinished headers and buffered OSC. Active streamed strings
  emit `end_of_input`, including when an ESC was pending.

## Storage limits

| Storage | Capacity |
| --- | --- |
| CSI/DCS values, including omitted and colon-separated entries | 32 |
| Intermediates | 4 bytes |
| Buffered OSC | 4096 payload bytes |
| UTF-8 | One scalar accumulator and continuation state |
| Streamed OSC/APC/DCS payload | No accumulated payload |

These capacities are public constants on `Parser`. Numbers saturate at 65535.
Parameter/intermediate overflow or malformed header ordering suppresses the
whole command. Buffered OSC overflow discards the whole payload through its
terminator; it never dispatches a truncated message. Streamed payloads have no
parser byte-count limit or counter that grows with transfer size. Consumers
supply transfer budgets. Parser memory stays fixed in all modes.

## Image integration

Enable the hooks with:

```zig
var parser = vt.Parser.initWithOptions(.{
    .osc_mode = .streaming,
    .apc_mode = .streaming,
});
```

`Session` routes APC beginning with `G` to a Kitty handler, OSC
command 1337 to an iTerm2 handler, and the appropriate DCS `q` header to a Sixel
handler when image handling is enabled. The parser forwards framing and bytes;
protocol implementation belongs to `Session`, separately from parsing.

The layers are:

```text
PTY bytes -> parser -> protocol handlers -> image decoding
                                        -> image storage and placement -> renderer
```

Protocol handlers manage metadata, multi-message transfers, base64,
compression, replies, and transfer budgets. Decoders validate formats,
output dimensions, and pixel-memory limits. Storage/placement manages image
IDs, cell anchors, scrolling, and deletion. Rendering owns texture
uploads, clipping, and drawing. These layers avoid putting an
allocator, file access, or graphics backend into the parser.

Treat streamed data as provisional until a successful ST/BEL ending. On
cancellation, interruption, EOF, or consumer rejection, discard incomplete
transfer state. Rejected transfers can continue draining parser events until
the ending; do not reset the parser mid-payload and expose the rest as text.
The GUI injects the vendored stb decoder. Portable consumers can inject their own
decoder or enable raw Kitty/Sixel images without one. See [media](media.md) for
the supported subset, limits, ownership contracts, and examples.

## Trace command and validation

`vertex parse` keeps buffered OSC output. `vertex parse --stream-strings`
prints OSC/APC begin/data/end events. All trace output is ASCII and escapes
incoming controls. Diagnostics use stderr; exit statuses are 0 for success or
help, 2 for argument errors, and 1 for I/O failures. Output flushes after each
available input chunk. The trace is a debugging format, not a stable wire format.

Run `zig test src/main.zig` locally. Tests cover text, command grammar, capacities,
stream lifetimes, arbitrary byte recovery, split input, and synthetic image
transport frames. CI runs Debug/ReleaseSafe tests, a separate module consumer,
executable smoke checks, and installation of Vertex's license. Build commands
are reserved for CI by the inherited repository instructions.
