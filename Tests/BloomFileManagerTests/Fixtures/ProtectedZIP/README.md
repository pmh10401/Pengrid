# Protected ZIP reader fixtures

These are independent, committed compatibility inputs for `LiveProtectedZIPEngine`.
The public passwords below are fixture data only; product code must not contain or
log them.

## Tool provenance

- Host: macOS 26.5.2, arm64.
- 7-Zip: official `7z2602-mac.tar.xz`, release `26.02` published 2026-06-26
  by `ip7z`. Download URL:
  `https://github.com/ip7z/7zip/releases/download/26.02/7z2602-mac.tar.xz`.
  GitHub release asset metadata reported size `1,859,992` bytes and SHA-256
  `1cf6760579502f87e591ff5c73a005ec50b3e4d6f507e8b038382d563c3175b9`.
  The temporary console tool reported `7-Zip (z) 26.02 (arm64)` and was not
  committed or added as a runtime dependency.
- Info-ZIP: `/usr/bin/zip` 3.0 (July 5th 2008).
- AES-128/AES-192: temporary generator linked against the pinned minizip-ng
  4.2.2 sources in `Sources/EncryptedZIPCore/vendor/minizip-ng`; it called
  `mz_zip_entry_write_open` with `aes_strength` 1 and 2. The generator was not
  committed.

## Reproduction commands

```sh
# Run from this directory with a temporary 7zz 26.02 console binary.
7zz a -tzip -mem=AES256 -p'fixture-aes256-passphrase' 7zip-aes256.zip 자료.txt
/usr/bin/zip -P 'fixture-zipcrypto-password' infozip-zipcrypto.zip Legacy.txt

# The temporary minizip generator used this per-entry call (strength 1, then 2):
# mz_zip_file info = {0};
# info.filename = "Strength.txt";
# info.flag = MZ_ZIP_FLAG_UTF8 | MZ_ZIP_FLAG_ENCRYPTED;
# info.compression_method = MZ_COMPRESS_METHOD_DEFLATE;
# info.aes_version = MZ_AES_VERSION;
# info.aes_strength = strength;
# mz_zip_entry_write_open(zip, &info, 6, 0, password);
# mz_zip_entry_write(zip, contents, contents_length);
# mz_zip_entry_close(zip);

/usr/bin/shasum -a 256 7zip-aes256.zip minizip-aes128.zip \
  minizip-aes192.zip infozip-zipcrypto.zip
```

## Contents and hashes

| Fixture | Encryption | Public password | Expected entry and UTF-8 bytes | SHA-256 |
| --- | --- | --- | --- | --- |
| `7zip-aes256.zip` | WinZip AES-256 | `fixture-aes256-passphrase` | `자료.txt` — `7-Zip AES-256 compatibility fixture\n` (36 bytes) | `136ca9275ad091af11e700886d0afb41d9be0c04804df22bdb39b098fed3f99c` |
| `minizip-aes128.zip` | WinZip AES-128 | `fixture-aes128-passphrase` | `Strength.txt` — `AES compatibility fixture\n` (26 bytes) | `b02a342fd9c6694155d7ee87c9e1eff12c2bdd69ac8dd23979db2085943efb75` |
| `minizip-aes192.zip` | WinZip AES-192 | `fixture-aes192-passphrase` | `Strength.txt` — `AES compatibility fixture\n` (26 bytes) | `6e501670d5e2259400b28f0f126ae257f17af125841fc08010e9112d5084c91e` |
| `infozip-zipcrypto.zip` | legacy ZipCrypto | `fixture-zipcrypto-password` | `Legacy.txt` — `Info-ZIP ZipCrypto compatibility fixture\n` (41 bytes) | `e9bcc8168d54002f0c8b0176db37b456e79864e6ebe3a89e259ad462c9a5ff0c` |
