# Pengrid Korean Initial Search Design

## Context

Pengrid's draft Smart Search recursively finds filenames and relative paths
below explicit local roots. It folds case and diacritics, tokenizes with
Foundation word boundaries, filters candidates by literal substring, and ranks
them with a deterministic BM25-style scorer. That behavior cannot match a
Korean initial-consonant query such as `ㅎㄱ` against `한국`, because the query
and document do not share literal text.

This increment adds Korean initial-consonant search without changing the saved
search schema, root safety rules, candidate bounds, cancellation behavior, or
the existing literal-search ranking contract.

## Goals

1. Match modern Korean initials typed with compatibility jamo or modern
   choseong jamo.
2. Support useful filename and relative-path cases such as:
   - `ㅎㄱ` matching `한국`, `한글`, and `한국어`; and
   - `ㄱㄷ` matching `기대` and `구글 드라이브`.
3. Allow Korean-initial clauses and literal clauses in the same query.
4. Keep literal-only English, Korean, numeric, and diacritic-insensitive search
   behavior unchanged.
5. Keep matching and ranking deterministic, bounded, cancellable, and local.
6. Explain the feature in the existing search UI without adding a mode toggle.

## Non-goals

- Full-text content search or persistent indexing.
- Fuzzy edit-distance matching or arbitrary initial subsequences.
- Old Hangul, compound-final compatibility jamo, or phonetic typo correction.
- A new saved-search format or a user preference for enabling the feature.
- Match highlighting in this increment. It requires a separate original-text
  range-mapping contract and is not needed to make the search discoverable.

## Approaches considered

### 1. Expand initials into regular expressions

Each initial could be converted into a Hangul syllable range. This is a small
patch, but compatibility jamo, modern choseong jamo, NFC/NFD filenames, and
word-initial matching would require special cases. Candidate filtering and
BM25 ranking would also use different representations, creating inconsistent
results.

### 2. Add a query plan and Korean-initial projection (selected)

Compile the query once into literal and initial clauses. Analyze documents into
the existing literal field plus bounded Korean-initial projections. Candidate
filtering and ranking consume the same query plan and projections. The design
preserves the literal fast path and isolates Unicode logic in a pure component.

### 3. Build a persistent n-gram or Spotlight index

An index could accelerate repeated searches, but introduces lifecycle,
permission, File Provider, and stale-data concerns. It conflicts with Smart
Search's current non-indexed, explicit-root scope.

## Selected behavior

### Supported initials

Only the 19 modern Hangul initials are recognized:

`ㄱ ㄲ ㄴ ㄷ ㄸ ㄹ ㅁ ㅂ ㅃ ㅅ ㅆ ㅇ ㅈ ㅉ ㅊ ㅋ ㅌ ㅍ ㅎ`

Compatibility jamo (`ㄱ` through `ㅎ` where the scalar maps to a modern
initial) and modern choseong jamo (`ᄀ` through `ᄒ`) map explicitly to the same
compatibility-jamo key. The analyzer does not apply global NFKC, because that
could change unrelated filename text. Compound finals and old-Hangul jamo stay
literal.

Document text is first normalized to NFC. This makes precomposed `한글` and a
canonically decomposed filesystem spelling equivalent. A modern Hangul
syllable in `U+AC00...U+D7A3` yields its initial with
`(scalar - 0xAC00) / 588`.

### Query clauses

`SmartSearchQueryPlan` compiles the trimmed query into ordered AND clauses:

- `.literal(String)` for the current folded text behavior; and
- `.hangulInitials(String)` for a consecutive run containing only supported
  initial jamo.

The analyzer retains current localized word boundaries and additionally splits
literal and supported-initial scalar runs inside a token. Therefore:

- `ㅎㄱ report` becomes initial `ㅎㄱ` AND literal `report`;
- `2026ㅎㄱ` becomes literal `2026` AND initial `ㅎㄱ`;
- `ㅎ ㄱ` remains two independent clauses rather than the phrase `ㅎㄱ`;
- `한국` stays a literal clause and is not automatically expanded to `ㅎㄱ`;
- extensions and punctuation retain their current literal behavior.

If compilation yields no searchable clauses, the service returns no results.
It never interprets such a query as matching every item.

### Document projections

`SmartSearchDocumentFeatures` contains the existing folded literal text and two
Korean-initial projections:

1. **Syllable runs**: each contiguous run of modern Hangul syllables becomes a
   full initial string. `한국` becomes `ㅎㄱ`; `드라이브` becomes `ㄷㄹㅇㅂ`.
2. **Run heads**: the first initial from each adjacent Hangul-containing text
   segment is concatenated. `구글 드라이브` becomes `ㄱㄷ`.

Whitespace, `/`, `-`, `_`, and `.` terminate a segment. A clause matches when
it is a consecutive substring of one syllable run or a consecutive substring
of a run-head string. Arbitrary subsequences are forbidden. Thus `ㄱㄷ`
matches `구글 드라이브`, while it does not match `개인 사진 다운로드`
whose run-head projection is `ㄱㅅㄷ`.

The analyzer creates initial projections only when the query plan contains an
initial clause. Literal-only searches remain on the current fast path.

## Architecture

### `SmartSearchTextAnalyzer`

A new pure, `Sendable` model component owns:

- explicit compatibility/choseong mapping;
- NFC normalization and existing case/diacritic folding;
- query-plan compilation;
- filename and path feature preparation; and
- clause-match classification.

It has no filesystem, Store, SwiftUI, or persistence dependency. Its output is
small value types that can be tested without mocks.

### Candidate preparation and search service

`LocalSmartSearchService` compiles one query plan before traversal. For each
eligible entry it prepares path features and applies every clause. Only
matching entries request cloud availability metadata and enter the bounded
candidate array.

An internal `PreparedSmartSearchCandidate` holds the existing result plus
filename/path features. The service sends prepared candidates to the ranker so
normalization and projection work is not repeated. The public model-level
ranking entry point remains source-compatible by preparing features internally
for existing tests and callers.

The current root validation, hidden/package/symlink policies, 50,000 hard
candidate bound, progress reporting, and cancellation checks remain unchanged.
Query compilation and long analysis/ranking loops also check cancellation.

### Ranking

Literal clauses retain the current tokenization, BM25 calculation, filename
multiplier, and exact/prefix/contains bonuses. A literal-only query must produce
the same candidate set, scores, and order as before this change.

Initial clauses add deterministic match-quality bonuses. The ordering contract
is:

1. literal filename exact/prefix/contains behavior remains strongest;
2. filename syllable-run exact, prefix, then contains;
3. filename run-head exact/prefix/contains;
4. relative-path syllable-run and run-head matches; and
5. existing standardized-path tie ordering.

Initial bonuses are lower than the corresponding literal bonuses, and filename
bonuses are greater than path-only bonuses. This makes a literal filename
`ㅎㄱ` outrank `한국`, makes `한국.pdf` outrank a path-only initial match, and
makes a compact syllable match outrank a word-head match when other evidence is
equal. Tests assert the ordering contract, not private numeric constants.

### Store and persistence

`SmartSearchStore`, `SmartSearchQuery`, and `SmartSearchRecord` do not gain new
stored fields. Existing saved searches containing initials begin using the new
matching behavior automatically. No persistence migration is needed.

## UI and accessibility

No search-mode toggle is added. The search field and idle guidance explain the
automatic behavior:

- field prompt: `Search names, paths, or Korean initials`;
- idle detail: `Try Korean initials such as ㅎㄱ for 한국 or 한글.`; and
- accessibility hint: `Korean initial searches are supported, for example ㅎㄱ.`

The result rows keep their current name, relative path, availability, double
click, keyboard, and VoiceOver behavior. Because matching mode is automatic,
VoiceOver does not announce a separate mode. Presentation tests verify the new
guidance and that the existing accessibility label remains intact.

## Failure handling and privacy

- Unsupported or malformed jamo remain literal and cannot broaden a search.
- Unicode analysis is pure and cannot fail traversal. If no clause matches,
  the entry is skipped before cloud metadata access.
- Errors continue to avoid exposing absolute paths in user-visible messages.
- Search remains metadata-only and never materializes cloud content.

## Test strategy

### Analyzer and model tests

- compatibility jamo and modern choseong equivalence;
- NFC and canonically decomposed filenames;
- all 19 initials including double initials;
- unsupported compound-final and old-Hangul jamo remain literal;
- `ㅎㄱ`, `ㄱㄷ`, `ㅎㄱ report`, and `2026ㅎㄱ` query plans;
- whitespace, punctuation, separators, paths, and extensions;
- syllable-run and run-head consecutive matching;
- rejection of arbitrary subsequences;
- literal `Café 보고서` tokenization regression; and
- literal-only score and ordering regression.

### Ranking tests

- literal filename match outranks an initial-derived match;
- initial filename exact outranks prefix, contains, run-head, and path-only;
- stable standardized-path ordering for equal scores; and
- cancellation while preparing or sorting large candidate sets.

### Service tests

- Korean files and folders across one and multiple roots;
- mixed literal and initial clauses use AND semantics;
- candidate/result caps, progress, and cancellation;
- hidden, package, symlink, and cloud availability policies remain unchanged;
- unsupported initial input does not return every entry.

### Presentation and UI verification

- prompt, idle guidance, and accessibility hint;
- search submission and result navigation regressions;
- manual macOS checks for Korean IME entry, Return submission, VoiceOver field
  hint, resizing, and light/dark appearances.

The focused Smart Search suites run after every red-green cycle. The full Swift
suite, release contract, arm64 build, and manual checklist are final gates.

## Performance constraints

- Query plans are compiled once per search.
- Literal-only searches do not create initial projections.
- Initial feature preparation is linear in the filename/path scalar count.
- No unbounded cache or index is introduced.
- Existing candidate and result bounds remain authoritative.
- A synthetic 50,000-candidate test guards cancellation and prevents accidental
  superlinear initial analysis.

## Design self-review

- **Ambiguity:** matching is explicitly consecutive within syllable runs or
  run heads; arbitrary subsequences are excluded.
- **Compatibility:** literal-only candidate, score, ordering, persistence, and
  safety contracts are unchanged.
- **Unicode:** supported scalar sets, normalization form, and unsupported-jamo
  behavior are explicit.
- **Scope:** indexing, highlighting, fuzzy search, new settings, and UI redesign
  are deferred.
- **Consistency:** the service and ranker consume one query-plan/analyzer
  contract, preventing a candidate/ranking mismatch.
- **Completeness:** architecture, data flow, failure handling, accessibility,
  performance, and automated/manual verification have concrete gates and no
  placeholders.
