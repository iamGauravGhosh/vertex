"""Rebuild tiny original rendering fixtures. Requires fonttools==4.60.1.
The generated fonts and this source are covered by Vertex's MIT license.
"""
from pathlib import Path
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.colorLib.builder import buildCOLR, buildCPAL

root = Path(__file__).resolve().parents[1] / 'tests/fonts'


def rectangle(x0, y0, x1, y1):
    pen = TTGlyphPen(None)
    pen.moveTo((x0, y0))
    pen.lineTo((x1, y0))
    pen.lineTo((x1, y1))
    pen.lineTo((x0, y1))
    pen.closePath()
    return pen.glyph()


for color in (False, True):
    name = 'Vertex Test Color' if color else 'Vertex Test Mono'
    glyphs = {'.notdef': rectangle(50, 0, 550, 700), 'space': TTGlyphPen(None).glyph(),
              'M': rectangle(50, 0, 550, 700), 'A': rectangle(100, 0, 500, 700)}
    cmap = {32: 'space', 65: 'A', 77: 'M'}
    if color:
        glyphs.update({'emoji': TTGlyphPen(None).glyph(),
                       'red': rectangle(0, 0, 1200, 700), 'green': rectangle(200, 200, 1000, 500)})
        cmap[0x1f600] = 'emoji'
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder(list(glyphs))
    builder.setupCharacterMap(cmap)
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({key: (1200 if key in ('emoji', 'red', 'green') else 600, 0) for key in glyphs})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable({'familyName': name, 'styleName': 'Regular', 'uniqueFontIdentifier': name,
                           'fullName': name, 'psName': name.replace(' ', '')})
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost()
    builder.setupMaxp()
    if color:
        builder.font['COLR'] = buildCOLR({'emoji': [('red', 0), ('green', 1)]}, version=0, glyphMap=builder.font.getReverseGlyphMap())
        builder.font['CPAL'] = buildCPAL([[(1, 0, 0, 1), (0, 1, 0, 1)]])
    builder.font['head'].created = 3800000000
    builder.font['head'].modified = 3800000000
    builder.font.recalcTimestamp = False
    builder.save(root / ('color.ttf' if color else 'mono.ttf'))
