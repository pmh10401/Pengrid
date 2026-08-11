# Pengrid README Product Landing Design

## Goal

Turn the English and Korean READMEs into concise product landing pages that
help a new visitor understand Pengrid, download the current build, and find
detailed documentation without reading a long feature manual.

## Audience

- macOS users deciding whether to download Pengrid
- contributors looking for the build and verification commands
- existing users looking for the current release and detailed guides

## Information Architecture

Both READMEs use the same section order:

1. centered Pengrid icon, product name, language switch, and one-sentence value proposition
2. current release download, requirements, verification count, checksum, and trust notice
3. a compact "Why Pengrid" summary focused on dual-pane work, keyboard use, and safe mutations
4. six scannable feature groups: workspace, search, preview and context actions, safe operations, archives, and cloud/accessibility tools
5. a small shortcut table for the highest-value commands
6. cloud and safety boundaries, including File Provider behavior and the absence of direct OAuth
7. source build commands and links to detailed documentation

## Content Rules

- Keep Preview 6, version 1.3.0 build 8, 1,407 tests in 92 suites, and the
  published DMG SHA-256 exactly aligned with the GitHub release.
- Keep the ad-hoc signature and non-notarized Gatekeeper warning prominent.
- Do not claim direct Google or Microsoft OAuth support. Describe Google Drive
  and OneDrive as macOS File Provider integrations.
- Do not claim manual checks that remain `NOT RUN` in verification documents.
- Preserve the internal `BloomFileManager` compatibility note, but move it to
  the source-build section where contributors need it.
- Move detailed transaction, identity, cancellation, archive-format, and Undo
  rules to the existing user guide and release notes instead of duplicating them.
- Keep English and Korean content structurally equivalent rather than literal
  sentence-by-sentence translations.

## Visual Treatment

- Reuse `Assets/Pengrid/AppIcon-1024.png` at the top; add no new binary asset.
- Use ordinary GitHub Markdown and HTML only for centered hero content.
- Avoid badges that depend on third-party services or unstable URLs.
- Keep tables limited to shortcuts and compact capability comparisons.

## Verification

- Check both README structures and all relative links.
- Confirm the release URL, DMG URL, version, build, test count, and SHA-256
  against the published GitHub release and local release documentation.
- Scan for stale preview numbers, unsupported OAuth claims, placeholders, and
  differences between English and Korean section coverage.
- Run `git diff --check` before committing the README implementation.
