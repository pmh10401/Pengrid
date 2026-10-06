# Third-party notices

## PenguinNotch / CodeNotch border movement and glass treatment

The perimeter projection and corner handoff in
`Sources/BloomFileManager/Support/ShelfEdgeMotion.swift` are adapted from the
MIT-licensed PenguinNotch checkout of CodeNotch (upstream:
<https://github.com/vinzdg/codenotch>). Pengrid uses its own shelf UI and native
SwiftUI spring and path rendering, not the original application as a dependency.
The shelf's optional system Liquid Glass and dark-glass background treatment
also follow PenguinNotch; folded and reduced-transparency surfaces stay solid.

```
MIT License

Copyright (c) 2026 Vinz

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
```

## minizip-ng 4.2.2

Pengrid vendors the minizip-ng 4.2.2 source snapshot at the upstream tag
commit `7b2387161c542fa9f427352dcdef76097d0d692b`.

- Upstream project: <https://github.com/zlib-ng/minizip-ng>
- Release/tag: <https://github.com/zlib-ng/minizip-ng/releases/tag/4.2.2>
- Vendor provenance: the files under `Sources/EncryptedZIPCore/vendor/minizip-ng/`
  are copied from that pinned tag; no floating dependency is used.
- Compression boundary: Store entries use raw stream bytes and do not use zlib.
  Deflate entries use the system zlib backend (`HAVE_ZLIB`).
- Crypto boundary: Package.swift excludes the upstream
  `vendor/minizip-ng/mz_strm_wzaes.c`, `vendor/minizip-ng/mz_crypt.c`, and
  `vendor/minizip-ng/mz_crypt_apple.c`, and
  `vendor/minizip-ng/mz_strm_pkcrypt.c` sources. Pengrid-owned replacements
  `pengrid_strm_wzaes.c`, `pengrid_crypt.c`, `pengrid_crypt_apple.c`, and
  `pengrid_strm_pkcrypt.c` provide compatible WinZip AES, PBKDF2, Apple crypto,
  and ZipCrypto stream boundaries. The replacement retains the pinned
  minizip-ng ABI and wire algorithm while clearing ZipCrypto derived state on
  open failure, close, and delete; it does not make an external
  interoperability or security-strength claim for legacy ZipCrypto beyond the
  committed fixture evidence.
- OpenSSL is not bundled and is not a runtime dependency of Pengrid.

The following license text is reproduced unmodified from the vendored upstream
license at `Sources/EncryptedZIPCore/vendor/minizip-ng/LICENSE`.

```
Condition of use and distribution are the same as zlib:

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgement in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```
