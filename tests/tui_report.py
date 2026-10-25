"""Escape-safe styled grid evidence; a reconstruction rather than GPU capture."""
import html
import json

PALETTE = [0x2e3440, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
           0x4c566a, 0xd08770, 0xb5d99c, 0xffdf9e, 0x81a1c1, 0xc6a0c9, 0x9dd9e5, 0xffffff]


def color(value, fallback):
    if "rgb" in value:
        c = value["rgb"]
        return "#%02x%02x%02x" % (c["r"], c["g"], c["b"])
    n = value.get("indexed")
    if n is None:
        return fallback
    if n < 16:
        return "#%06x" % PALETTE[n]
    if n >= 232:
        return "#%02x%02x%02x" % ((8 + (n - 232) * 10,) * 3)
    n -= 16
    cube = [0, 95, 135, 175, 215, 255]
    return "#%02x%02x%02x" % (cube[n // 36], cube[n // 6 % 6], cube[n % 6])


def report(state, destination):
    cells = []
    for r, row in enumerate(state.get("graphemes", [])):
        for c, cluster in enumerate(row):
            width = state["widths"][r][c]
            if width == 0:
                continue
            style = state["styles"][r][c]
            fg, bg = color(style["foreground"], "#d8dee9"), color(style["background"], "#15171a")
            if style["inverse"]:
                fg, bg = bg, fg
            css = f"color:{fg};background:{bg};grid-column:span {width};"
            if style["bold"]:
                css += "font-weight:bold;"
            if style["italic"]:
                css += "font-style:italic;"
            if style["underline"]:
                kind = {"single": "solid", "double": "double", "curly": "wavy", "dotted": "dotted", "dashed": "dashed"}[style["underline_style"]]
                css += f"text-decoration:underline {kind} {color(style['underline_color'], fg)};"
            text = "" if style["hidden"] else "".join(map(chr, cluster))
            cells.append(f'<span style="{css}">{html.escape(text) or " "}</span>')
    destination.write_text('<!doctype html><meta charset="utf-8"><title>Vertex TUI grid evidence</title>'
                           '<style>body{background:#101216;color:#ddd}main{display:grid;font:16px/1.25 monospace;'
                           f'grid-template-columns:repeat({state["columns"]},1ch);width:max-content}}span{{white-space:pre}}</style>'
                           '<p>Vertex application grid reconstruction</p><main>' + "".join(cells) + '</main><pre>' +
                           html.escape(json.dumps({k: state[k] for k in ("cursor", "modes", "alternate")}, indent=2)) + '</pre>')
