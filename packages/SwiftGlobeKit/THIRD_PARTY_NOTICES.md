# Third-Party Notices

## COBE

The three-pass rendering structure and spherical-Fibonacci dot treatment are
adapted from [COBE](https://github.com/shuding/cobe). SwiftGlobeKit replaces
COBE's web runtime, shader language, API, and bundled map texture with native
SwiftUI, Metal, and the Natural Earth asset documented below.

COBE is distributed under the MIT License:

MIT License

Copyright (c) 2021 Shu Ding

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Natural Earth

`Sources/SwiftGlobeKit/Resources/LandMask.png` is generated directly from
Natural Earth's 1:110m land polygons:

- Dataset: `ne_110m_land.geojson`
- Repository: <https://github.com/nvkelso/natural-earth-vector>
- Pinned commit: `f1890d9f152c896d250a77557a5751a93d494776` (Natural Earth v5.1.2)
- Source:
  <https://raw.githubusercontent.com/nvkelso/natural-earth-vector/f1890d9f152c896d250a77557a5751a93d494776/geojson/ne_110m_land.geojson>
- Source SHA-256:
  `9e0729ee253ca7d7a5c4ae9395fb1902264c5377c52e224d13dd85010e2835d9`

Natural Earth states that all versions of its raster and vector map data are in
the public domain and may be used and modified without permission or required
credit:

<https://www.naturalearthdata.com/about/terms-of-use/>

The generated derivative is a 256x128 equirectangular, 1-bit grayscale PNG:
white pixels represent land and black pixels represent water. It is not copied
from or derived from COBE's bundled texture. Its SHA-256 is
`b00eb21e29b2efe4b0a47595db420c158ec1babe2d65fe6d16d505ab6b093f44`.
