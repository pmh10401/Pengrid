# Pengrid Korean Initial Search Design

## Context

Pengrid's draft Smart Search recursively finds filenames and relative paths
below explicit local roots. It folds case and diacritics, tokenizes with
Foundation word boundaries, filters candidates by literal substring, and ranks
them with a deterministic BM25-style scorer. That behavior cannot match a
Korean initial-consonant query such as `ㅎㄱ` against `한국`, because the query
and document do not share literal text.

This increment adds Korean initial-consonant search without changing the saved
search JSON schema, root safety rules, candidate bounds, cancellation behavior,
or the existing literal-search ranking contract.

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

If compilation yields no searchable clauses, a new query fails validation with
clear guidance. A legacy saved query in that form still decodes, but execution
fails before traversal. Pengrid never interprets it as matching every item.

New queries accept at most 512 Unicode scalars and 16 compiled clauses. The
scalar limit is checked before compilation, and the clause limit is checked
before traversal, so retained evidence is bounded by candidates times 16.
Decoding remains migration-safe: an older saved query over either limit keeps
its original text and roots but has no executable plan until the user shortens
it.

### Document projections

`SmartSearchDocumentFeatures` contains the existing folded literal text and two
Korean-initial projections:

1. **Syllable runs**: each contiguous run of modern Hangul syllables becomes a
   full initial string. `한국` becomes `ㅎㄱ`; `드라이브` becomes `ㄷㄹㅇㅂ`.
2. **Run heads**: the first initial from each adjacent Hangul-containing text
   segment is concatenated. `구글 드라이브` becomes `ㄱㄷ`.
3. **Explicit-initial runs**: standalone compatibility or modern choseong jamo
   are canonicalized to compatibility jamo. This lets a literal filename
   `ㅎㄱ.txt` receive literal evidence when the query is `ㅎㄱ`.

A segment is a maximal sequence of Unicode letters or decimal digits. Every
other scalar, including whitespace, `/`, `-`, `_`, `.`, parentheses, and other
punctuation, terminates the segment. A segment contributes at most one run head:
the first modern Hangul syllable or explicit supported initial in that segment.
Consecutive Hangul-containing segments form one run-head group. A segment with
no supported Hangul syllable or initial ends the group. Consequently:

- `구글(드라이브)` and `구글/드라이브` produce run-head group `ㄱㄷ`;
- `구글/2026/드라이브` produces separate groups `ㄱ` and `ㄷ`; and
- `구글Drive드라이브` is one segment and contributes only head `ㄱ`.

An initial clause first checks canonicalized explicit-initial runs as literal
evidence. Otherwise it matches when it is a consecutive substring of one
syllable run or a consecutive substring of one run-head group. Arbitrary
subsequences are forbidden. Thus `ㄱㄷ` matches `구글 드라이브`, while it does
not match `개인 사진 다운로드` whose run-head projection is `ㄱㅅㄷ`.

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

`SmartSearchQuery` prepares one bounded query plan during validation, and
`LocalSmartSearchService` reuses it before traversal. For each
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
Query compilation and long analysis, matching, document-frequency, scoring,
and merge-sort loops expose cancellation checks.

### Ranking

Literal clauses retain the current tokenization, BM25 calculation, filename
multiplier, and exact/prefix/contains bonuses. A literal-only query must produce
the same candidate set, scores, and order as before this change.

Initial clauses add deterministic evidence and a virtual BM25 field. Every
matching initial clause records a tuple:

`(field, representation, relation)`

- `field`: filename `2`, relative path `1`;
- `representation`: canonicalized explicit-initial literal `3`, syllable run
  `2`, run head `1`; and
- `relation`: exact `3`, prefix `2`, contains `1`.

Tuples compare lexicographically, higher first. For multiple initial clauses,
each candidate's tuples are sorted weakest-first and the tuple arrays compare
lexicographically. This max-min ordering prevents one excellent clause from
hiding a poor match for another clause. It also guarantees that a literal
filename `ㅎㄱ` outranks derived `한국`, filename syllable evidence outranks
filename run-head evidence, and every filename match outranks path-only
evidence.

Within the same evidence tuple array, initial relevance uses the existing BM25
constants `k1 = 1.2` and `b = 0.75`. A consecutive occurrence in a syllable or
explicit-initial run contributes TF `1.0`; an occurrence in a run-head group
contributes TF `0.5`. Filename TF is multiplied by `3`; path TF is not. Document
length is the count of supported initials in that virtual field, clamped to at
least `1`; average length is computed across prepared candidates. IDF uses the
current formula and the number of candidates whose corresponding field contains
the clause. The existing literal BM25 score and the initial virtual-field score
are added only after evidence tuples compare equal.

The final comparison order is: initial evidence tuple array when present,
combined relevance score, then the existing standardized-path tie ordering.
Literal-only queries bypass initial evidence and therefore retain the exact
current score and ordering behavior.

### Store and persistence

The saved-search JSON schema does not gain a field. `SmartSearchQuery` retains
its compiled plan only in memory and omits it from `Codable`. Existing saved
searches containing initials begin using the new matching behavior
automatically. Legacy searches over the new complexity limits still decode and
remain visible alongside other saved searches; opening one produces the clear
`Search is too long. Use fewer terms.` state without touching the filesystem.
Queries that cannot execute also disable **Save Search**, and the saved-name
draft is cleared only after a record is actually created. No persistence
migration is needed.

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
- A query over 512 Unicode scalars or 16 compiled clauses fails before
  filesystem traversal and asks the user to shorten it.
- A punctuation- or emoji-only query fails before traversal with
  `Search needs a filename, path, or Korean initials.`
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
- Initial substring matching uses a precomputed KMP failure table, counts
  overlapping matches, and stays linear in pattern plus candidate length.
- No unbounded cache or index is introduced.
- Existing candidate and result bounds remain authoritative, and each query
  retains evidence for no more than 16 clauses per candidate.
- A synthetic 50,000-candidate test guards cancellation after merge sort has
  started; a separate probe interrupts initial-field statistics collection.
- An internal analyzer step hook, defaulting to a no-op, is invoked during
  scalar analysis, failure-table construction, and initial matching. Tests
  compare work units for proportionally doubled adversarial inputs and require
  the work to stay within `2x + constant`, avoiding a brittle wall-clock gate.

## Design self-review

- **Ambiguity:** segment boundaries, run-head grouping, literal initial
  fallback, and consecutive matching are explicit; arbitrary subsequences are
  excluded.
- **Compatibility:** literal-only candidate, score, ordering, persistence, and
  safety contracts are unchanged.
- **Unicode:** supported scalar sets, normalization form, and unsupported-jamo
  behavior are explicit.
- **Scope:** indexing, highlighting, fuzzy search, new settings, and UI redesign
  are deferred.
- **Consistency:** the service and ranker consume one query-plan/analyzer
  contract, and ranking has a complete evidence tuple plus virtual-BM25 order,
  preventing candidate/ranking mismatches or unbounded bonus interactions.
- **Completeness:** architecture, data flow, failure handling, accessibility,
  performance, and automated/manual verification have concrete gates and no
  placeholders.
