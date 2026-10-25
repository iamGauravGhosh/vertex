"""Rebuild tiny original rendering fixtures. Requires fonttools==4.60.1.
The generated fonts and this source are covered by Vertex's MIT license.
"""
from pathlib import Path
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.colorLib.builder import buildCOLR, buildCPAL
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString

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
        # Deliberately compete with a monochrome supplementary PUA icon.
        cmap[0xf0001] = 'emoji'
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


def frame():
    """Four thick edges make clipping distinguishable from correct fitting."""
    pen = TTGlyphPen(None)
    for x0, y0, x1, y1 in [(-250, -400, -50, 1200), (1050, -400, 1250, 1200),
                           (-50, -400, 1050, -200), (-50, 1000, 1050, 1200)]:
        pen.moveTo((x0, y0))
        pen.lineTo((x1, y0))
        pen.lineTo((x1, y1))
        pen.lineTo((x0, y1))
        pen.closePath()
    return pen.glyph()


for proportional in (False, True):
    name = 'Vertex Test Proportional' if proportional else 'Vertex Test Icons'
    glyphs = {'.notdef': rectangle(50, 0, 550, 700), 'wide': frame()}
    cmap = {0xe0b0: 'wide', 0xe700: 'wide', 0xf0001: 'wide', 0x100001: 'wide'}
    advances = {'.notdef': 600, 'wide': 1600}
    if proportional:
        glyphs.update({'space': TTGlyphPen(None).glyph(), 'M': rectangle(50, 0, 550, 700),
                       'A': rectangle(100, 0, 500, 700), 'i': rectangle(25, 0, 175, 700),
                       'W': rectangle(0, 0, 850, 700), 'O': rectangle(-200, 0, 1000, 700),
                       'acute': rectangle(-80, 0, 80, 160),
                       'alef': rectangle(0, 0, 350, 700), 'bet': rectangle(0, 0, 650, 700)})
        cmap.update({32: 'space', 65: 'A', 77: 'M', 105: 'i', 87: 'W', 79: 'O',
                     0x301: 'acute', 0x5d0: 'alef', 0x5d1: 'bet', 0x754c: 'wide'})
        advances.update({'space': 200, 'M': 600, 'A': 600, 'i': 200, 'W': 900,
                         'O': 400, 'acute': 0, 'alef': 400, 'bet': 700})
    builder = FontBuilder(1000, isTTF=True)
    builder.setupGlyphOrder(list(glyphs))
    builder.setupCharacterMap(cmap)
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({key: (advances[key], glyph.xMin if glyph.numberOfContours else 0)
                                    for key, glyph in glyphs.items()})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable({'familyName': name, 'styleName': 'Regular', 'uniqueFontIdentifier': name,
                           'fullName': name, 'psName': name.replace(' ', '')})
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    builder.setupPost()
    builder.setupMaxp()
    if proportional:
        addOpenTypeFeaturesFromString(builder.font, '''
            feature liga { sub i i by wide; } liga;
            markClass acute <anchor 0 0> @TOP;
            feature mark { pos base A <anchor 300 900> mark @TOP; } mark;
        ''')
    builder.font['head'].created = 3800000000
    builder.font['head'].modified = 3800000000
    builder.font.recalcTimestamp = False
    builder.save(root / ('proportional.ttf' if proportional else 'icons.ttf'))

# A real four-face family distinguishes style selection from synthetic transforms.
for bold, italic in ((False, False), (True, False), (False, True), (True, True)):
    family = 'Vertex Test Styled'
    style = ('Bold' if bold else '') + ('Italic' if italic else '') or 'Regular'
    builder = FontBuilder(1000, isTTF=True)
    glyphs = {'.notdef': rectangle(50, 0, 550, 700), 'space': TTGlyphPen(None).glyph(),
              'M': rectangle(50, 0, 550, 700),
              'A': rectangle(50, 0, 550 if bold else 400, 750 if italic else 700)}
    builder.setupGlyphOrder(list(glyphs))
    builder.setupCharacterMap({32: 'space', 65: 'A', 77: 'M'})
    builder.setupGlyf(glyphs)
    builder.setupHorizontalMetrics({key: (600, 0) for key in glyphs})
    builder.setupHorizontalHeader(ascent=800, descent=-200)
    builder.setupNameTable({'familyName': family, 'styleName': style,
        'uniqueFontIdentifier': family+style, 'fullName': family+' '+style,
        'psName': family.replace(' ', '')+'-'+style})
    builder.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800,
        usWinDescent=200, usWeightClass=700 if bold else 400,
        fsSelection=(32 if bold else 0) | (1 if italic else 0) | (64 if not bold and not italic else 0))
    builder.setupPost(italicAngle=-12 if italic else 0, isFixedPitch=1)
    builder.setupMaxp()
    builder.font['head'].macStyle = int(bold) | (int(italic) << 1)
    builder.font['head'].created = builder.font['head'].modified = 3800000000
    builder.font.recalcTimestamp = False
    builder.save(root / ('styled-'+style.lower()+'.ttf'))
