# Pengrid direct release

Pengrid is distributed directly for Apple Silicon Macs running macOS 15 or newer. The release does not use App Sandbox entitlements. Its executable filename and compatibility-sensitive internal identity remain `BloomFileManager`.

## Version 1.3 release gates

Version 1.3 adds ZIP and TAR-family compression and extraction: **ZIP**,
**TAR**, **TAR.GZ**/**TGZ**, **TAR.BZ2**/**TBZ**/**TBZ2**, and
**TAR.XZ**/**TXZ**. New TAR-family archives use canonical `.tar`, `.tar.gz`,
`.tar.bz2`, and `.tar.xz` extensions; the short forms are recognized for
extraction. The feature also includes safe staged publication, multi-item
compression, cloud File Provider access, selected symbolic-link preservation,
cancellation safety, and VoiceOver-aware archive status. During multi-source
compression, parallelism is limited to staging copies in the private aggregate
directory, bounded to at most four workers and never beyond available
processors or sources; archiving and extraction remain single native tool
operations. Password-protected archives and RAR and 7z archives are excluded.
The feature gate is not passed until every required automated and static check
is current and every physical-manual scenario in
[`docs/verification/version-1.3-archive-checklist.md`](verification/version-1.3-archive-checklist.md)
has recorded evidence.

## Version 1.2 release gates

Version 1.2 introduced pane-local filename filtering, navigation history,
session restoration, and live Quick Look. Its historical verification record
remains in
[`docs/verification/version-1.2-checklist.md`](verification/version-1.2-checklist.md).

In particular, a release candidate still requires physical checks with local, external,
and case-sensitive volumes; disconnect/reconnect during comparison and transfer; large
files; VoiceOver and Full Keyboard Access; Increased Contrast, Reduce Motion, Light Mode,
and Dark Mode. Automated fixtures and source inspection do not replace those checks.

The distribution gate also remains open until the exact candidate has been signed with a
valid Developer ID Application identity, accepted by Apple notarization, stapled and
validated, and accepted by Gatekeeper. An unsigned package is suitable only for local
inspection or an explicitly labelled Developer Preview; it must not be described as a
signed public release.

## Local unsigned package and Developer Preview

Command Line Tools are sufficient for local packaging on an Apple Silicon Mac:

```bash
./script/package_release.sh --unsigned
codesign --verify --deep --strict --verbose=2 dist/release/Pengrid.app
file dist/release/Pengrid.app/Contents/MacOS/BloomFileManager
plutil -p dist/release/Pengrid.app/Contents/Info.plist
codesign -dvvv --entitlements :- dist/release/Pengrid.app
hdiutil verify dist/release/Pengrid.dmg
```

The app and DMG are ad-hoc signed for local inspection. They are not a
distributable Developer ID release and Gatekeeper is not expected to accept
them as one. An unsigned GitHub **Developer Preview** may be published only
when its prerelease title and notes clearly state this trust warning; it must
not be presented as a signed public release.

In an ordinary local workspace, `dist/release/Pengrid.app` is the real app directory. If the repository is under a File Provider-managed Documents folder, the script instead makes that path a symlink to a versioned real bundle in the current user's cache. This prevents repeatedly attached Finder metadata from invalidating the signature. After a successful replacement, the script removes the previous version only when its canonical path and filesystem identity prove that it is a directly owned cache version; external symlink targets are never removed. Deleting the cache can therefore break the local app link; rerunning the package script recreates it. The signed ZIP is always self-contained, contains no cache symlink, and is one of the signed distribution artifacts.

Unsigned mode ad-hoc signs and replaces `Pengrid.app` and `Pengrid.dmg`. It
does not produce or replace `Pengrid.zip` and intentionally preserves any
existing ZIP, which may represent an older signed and notarized release.
Signed mode produces the app, ZIP, and DMG artifacts. Never distribute a
preserved ZIP as if it were produced by the latest unsigned run.

## Signed and notarized package

Install full Xcode, accept its license, and select it before making a signed release:

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -version
xcrun --find notarytool
xcrun --find stapler
```

Install a `Developer ID Application` certificate in the login keychain. Confirm only that a valid signing identity is available; do not paste certificate or credential output into issues or build logs:

```bash
security find-identity -p codesigning -v
```

Create a keychain profile once. Use an Apple app-specific password and keep all credential values outside the repository:

```bash
export NOTARY_PROFILE='BloomNotary'
read -r APPLE_ID
read -r TEAM_ID
read -rs APP_SPECIFIC_PASSWORD
xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD"
unset APPLE_ID TEAM_ID APP_SPECIFIC_PASSWORD
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
```

Set the exact certificate display name and profile name, then run the signed release command:

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: Example Name (TEAMID1234)'
export NOTARY_PROFILE='BloomNotary'
./script/package_release.sh --signed
```

Before tests or builds, signed mode verifies the exact Developer ID Application identity and runs `notarytool history` against the selected keychain profile. The script then tests and builds the release product, verifies an exact arm64-only executable, signs it with hardened runtime and a secure timestamp, submits a private `ditto --keepParent` archive, and requires a structured `Accepted` result. It staples and validates the private app, recreates and independently extracts/verifies the final ZIP, creates and verifies the DMG, and only then transactionally replaces the public app, ZIP, and DMG. A failure, explicit exit, interrupt, or termination signal during publication runs identity-checked rollback before cleanup, leaving the previous release paths unchanged.

Verify the final artifacts:

```bash
codesign --verify --deep --strict --verbose=2 dist/release/Pengrid.app
codesign -dvvv --entitlements :- dist/release/Pengrid.app
xcrun stapler validate dist/release/Pengrid.app
spctl --assess --type execute --verbose=4 dist/release/Pengrid.app
ditto -x -k dist/release/Pengrid.zip /tmp/pengrid-release-inspection
hdiutil verify dist/release/Pengrid.dmg
```

`spctl` must report an accepted Developer ID source. The entitlements output must not contain `com.apple.security.app-sandbox`.

## Recover from a rejected submission

The script stores `submission.json` and `submission.plist` in a private per-user diagnostic directory before extracting required fields and prints that path on failure. A malformed response or one missing `id` or `status` therefore remains available for diagnosis. For a rejected submission with a valid ID it also downloads `notary-log.json`. Do not retry blindly. Query that submission ID and inspect its log:

```bash
xcrun notarytool info SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE"
xcrun notarytool log SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE" notarization-log.json
```

Inspect `notarization-log.json`, correct every reported signing, bundle, or hardened-runtime problem, and rerun `./script/package_release.sh --signed`. Do not staple the previous public app after a failed transactional run: it is intentionally still the prior release. A successful rerun staples and validates the exact accepted candidate before publication.

After a successful run, ticket validation is:

```bash
xcrun stapler validate dist/release/Pengrid.app
```

The transfer engine supports regular files, directories, and symbolic links. Device nodes,
sockets, FIFOs, and other special filesystem entries are rejected with a per-item failure;
they are not copied as regular data. A physical cross-volume move remains a required manual
release check because the automated suite can only exercise simulated volume identifiers.
