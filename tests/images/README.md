# Raster fixtures

Original, generated test images, covered by Vertex's MIT license:

- `rgba.png`: 2×2 RGBA: opaque red, half-alpha green, opaque blue, transparent white.
- `rgb.jpg`: 2×2 RGB: red, green, blue, white; encoded using libjpeg-turbo cjpeg,
  quality 100, no chroma subsampling.
- `animated.gif`: two 1×1 frames, red then blue. Static decoding must return red.

No image tools are needed to run the tests.
