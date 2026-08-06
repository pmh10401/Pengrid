# Third-party notices

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
  `vendor/minizip-ng/mz_crypt_apple.c` sources. Pengrid-owned replacements
  `pengrid_strm_wzaes.c`, `pengrid_crypt.c`, and `pengrid_crypt_apple.c` provide
  the compatible WinZip AES stream, PBKDF2, and Apple crypto boundary using the
  system frameworks linked by this target. The compiled ZipCrypto stream is
  the upstream `vendor/minizip-ng/mz_strm_pkcrypt.c` source enabled by
  `HAVE_PKCRYPT`.
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
