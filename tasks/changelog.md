# Changelog

Milestones in the AI Book Reader port. Format: `## YYYY-MM-DD — what shipped`.

## 2026-05-21 — Stage A tuning iteration (uncommitted)

Builds on the term-extraction pipeline (iterations 7-8 in `migration_plan.md`, still uncommitted) by reshaping how Stage A scores, filters, and caps its candidate pool. Headline numbers on the Solo Leveling 8-volume Yen Press benchmark:

| | Pool size | strict vs Wiki | loose vs Wiki |
|---|---:|---:|---:|
| Before tuning (top-N=1515 cap) | 1 515 | 61.2% | 87.4% |
| **After tuning** | **2 250** (score-driven) | **68.9%** | **95.6%** |

C-value runtime dropped from ~3.0 s to ~0.3 s (−90%); total Stage A from ~27 s to ~11 s.

Single source of truth for the iteration is [`tasks/stage_a_tuning.md`](stage_a_tuning.md) — keep-list of 10 working changes, failed-experiment log (E `log(1+freq)`, F stopword-ratio for chains, B `[…]` bracket pattern — all rolled back), and 7 open ideas.

What landed across `lib/service/pipeline/discovery/`:

- **new** `text_artifacts.dart` — `cleanTermArtifacts`: strips end-of-sentence punctuation (`.,!?;:…` and CJK siblings) and collapses runs of >2 identical chars to 2. `Ah!`, `Ahhh!!`, `Ahhhh……` collapse to `Ahh`.
- `candidate_generator.dart` — calls `cleanTermArtifacts` in both `_emitSpan` and `_ingestQuotedSpans`. Adds a universal stopword-guard inside `_ingestQuotedSpans`: first/last token can't be a stopword, and `≥50%` of the tokens can't be stopwords either. Cuts dialogue fragments (`Are you Hunter Jinwoo Sung`) regardless of language thanks to the stopwords-iso list already shipping with the app.
- `cvalue_scorer.dart` — type boost (`proper_name ×1.4`, `title / organization ×1.3`, `technique ×1.2`) re-uses the existing classifier signal. **Inverse-U length factor** replaces classic Frantzi `log2(wordCount)`: factors `1: 1.2, 2: 1.5, 3: 1.2, 4: 0.7, 5: 0.4, 6+: 0.2`. Glossary terms in narrative text are 1-3 words; 5+ word "chains" are almost always dialogue or System messages.
- `substring_penalizer.dart` — frequent proper-names with `freq ≥ 10` get a softer `0.6×` penalty instead of the default `~0.3×`. Rescues `Adam White`, `Sung Jinwoo`, `Metus` from being pushed out by `Sung Jinwoo's Hunter Guild`-style super-spans.
- `dispersion_scorer.dart` — Gries DP runs on every candidate (no `topK` cap); evenly-distributed low-frequency terms get the same up-to-2× boost as the head. Adds a `×1.2` recency bonus for candidates first introduced in the first third of the book with `freq ≥ 5` (catches main-cast names regardless of language).
- `tokenizer.dart` — `Token.normalizedText` strips trailing English possessive `['’ʼ]s`. `Kamish's` → `kamish`. The original `text` keeps the apostrophe for display.
- `term_discovery_isolate.dart` — adds a **heuristic junk filter** at Etap 1.3 (before C-value, since C-value is O(K²)). Drops candidates where `chapter_count == 1` AND `frequency_total ≤ 2`, plus candidates with `≥ 5` total words. Cuts ~51% of the pool on Solo Leveling (`Skraah Skree`, `Hp Hp`, `Atm`, `Sliced Pork Belly`, `Shadow Extraction has failed`, etc.) at the cost of 9 wiki canonicals (4 direct + 5 indirect through cluster-rep shuffling). Also adds `DiscoveryInput.minScore = 0.0` and a post-sort score-floor cut so the zero-score tail is dropped.
- `term_discovery_constants.dart` — new constants `heuristicJunkSingleChapterMaxFreq = 2`, `heuristicJunkLongPhraseWordCount = 5`. Anchor for `adaptiveDiscoveryTopN` raised `1 500 → 3 000`; ceiling raised `5 000 → 30 000`. `topN` is now a safety net; the `score > 0` floor is the primary cutoff. On Solo Leveling (102 ch) the resulting pool is 2 250 (score-driven); on Sword God projection (2 600 ch) it should be ~12 000 instead of being clamped at 5 000.

Benchmark instrument additions (`benchmarks/term_extraction/`):

- `bin/run_benchmark.dart` — new flags `--terms-json=<path>` (treat a flat JSON array of strings as the candidate source) and `--ground-truth=<path>` (override the categorised wiki GT with another wiki JSON or a flat array).
- new `lib/term_normalizer.dart` + `tool/normalize_terms.dart` + `tool/normalize_stage_a.dart` — shared case+hyphen+plural folding used to dedupe LLM glossary output. Stage A internally dedups on lower-case `normalizedSource`, so applying the normaliser to Stage A output is currently a no-op (kept for symmetry).
- new `tool/merge_volume_terms.dart` — merges 8 per-volume LLM extractions for Solo Leveling into the 873-term `extracted_terms_normalized.json`. The 590-term filtered variant (`extracted_terms_filtered.json`) is a debug artefact, not a benchmark target.

Failed experiments rolled back (recorded in `tasks/stage_a_tuning.md` to prevent rediscovery):

1. `log(1 + freq)` frequency compression — collapsed main characters into the tail; Sung Jinwoo lost dominance, strict recall at top-1515 dropped 64.5 → 48.1.
2. Stopword-ratio penalty for capitalized chains — stopwords-iso's `the`, `of`, `in` are exactly the connectors the chain assembler uses; `King of the Dead`-style wiki canonicals got rejected.
3. `[…]` bracket pattern in `_ingestQuotedSpans` — Yen Press translation wraps whole System sentences in brackets, not skill names; added 188 noisy candidates for 1 wiki strict-hit. Re-attempting this needs structural parsing of the bracket content (run `_emitSpan` on the inside), not whole-content ingestion. Recorded as open idea #1.

Verification done: `flutter analyze lib/service/pipeline/discovery/` clean; benchmark prompts re-run against Solo Leveling 8-volume Yen Press corpus; final numbers match the 2 250 / 68.9% / 95.6% snapshot above.

**Not done yet** (queued in `active_context.md` § "What still needs to happen"):

- On-device verification: `flutter run -d <device>`, hot-restart, trigger term extraction on a real book, confirm `tb_term_candidates` row count matches benchmark expectation.
- Multi-language smoke (Ukrainian / Russian EPUB) to confirm stopwords path and scoring boosts behave correctly outside English.
- `minScore` parameter on `TermDiscoveryService.discoverIfNeeded` (currently uses `DiscoveryInput.minScore = 0.0` default).
- Open ideas #1 (bracket-content chain extraction), #2 (lowercase channel for high-frequency plurals), #4 (morphology clusterer picks display form by uppercase/dash, not just frequency).

## 2026-05-10 — Iteration 3.5: reference translations + chapter-number alignment (uncommitted)

User-attached human translations now live alongside the original book. On the book detail page a new card lets the user drop or pick `.epub` / `.fb2` files (multi-select; desktop drag-and-drop). Each part is parsed into its own table, chapters merged for sub-chapter formats (`1.1 / 1.2 / 1.3 → 1`), and aligned to the original by `chapter_number`.

- `lib/dao/database.dart` — DB version 9 → 10. Migration `case 9:` adds `tb_source_chapters.chapter_number INTEGER`, the new `tb_reference_translations` and `tb_reference_chapters` tables, plus alignment / lookup indexes. No destructive UPDATE in the migration.
- `lib/utils/chapter_number_extractor.dart` — pulls a numeric chapter id from a title (with optional content fallback), gated by the universal regex from [lib/models/chapter_split_presets.dart](lib/models/chapter_split_presets.dart) (`Default (mixed languages)`). No LLM, no Chinese-numeral conversion this iteration.
- `lib/service/pipeline/chapter_merger.dart` — groups raw chapters by `chapter_number`, concatenates sub-chapter content (`\n\n`-joined), records `merged_from` in `meta` JSON.
- `lib/service/pipeline/chapter_parser_service.dart` — now runs every fetched book through `ChapterMerger` before persisting; back-fills `chapter_number` for v9-era rows via `backfillChapterNumbersForBook`.
- `lib/service/pipeline/reference_translation_parser_service.dart` — new headless `AnxHeadlessWebView` parser; `importing=false` URL flag; stub handlers for `onLoadEnd` / `renderAnnotations`; same poll-then-fetch JS as the in-reader parser.
- `lib/models/reference_translation.dart`, `lib/models/reference_chapter.dart` + `lib/dao/reference_translation_dao.dart`, `lib/dao/reference_chapter_dao.dart` — DAOs follow `SourceChapterDao` template; `deleteById` is transactional (chapters then row); `selectAlignedWithSource(bookId)` exposes the JOIN for future glossary work.
- `lib/providers/reference_translations.dart` — `@Riverpod(keepAlive: true)` on `bookId`; serialises Add operations into a single Future chain (one WebView at a time); deletes also remove the on-disk file.
- `lib/widgets/book_detail/reference_translations_card.dart` — UI card with FilePicker, desktop-drop overlay, per-part status row (idle / running / parsed / failed), confirmation dialog on delete.
- `lib/page/book_detail.dart` — card mounted in `buildMoreDetail` directly under `ChapterParsingStatusCard`.
- `lib/l10n/app_en.arb` — 13 new keys for the section.

Known limitations:
- Books parsed before v10 only have `chapter_number` lazily back-filled; sub-chapter merge is **not** retroactive (would require a re-parse pass).
- Chinese numerals (`第一章`) are detected by the chapter-rule regex but stay unaligned (no digit conversion).
- Soft-delete of a book does not cascade-clean `tb_reference_translations` / chapters / files (matches the existing project pattern; standalone fix later).
- Web drag-and-drop deferred (`desktop_drop` does not support Web).

Verification done: `dart run build_runner build --delete-conflicting-outputs` clean; `flutter analyze` clean on every touched file; `flutter gen-l10n` regenerated `L10n` for all locales.

First runtime smoke crashed on Windows ("Lost connection to device") right after foliate-js loaded `paginator.js` for the dropped reference file. Root cause: `HeadlessInAppWebView` on Windows has no rendering surface, and foliate-js with `importing=false` initialises its paginator and tries to render — WebView2 crashes natively.

Second smoke run no longer crashed but the upload silently hung (UI stuck on "parsing"). Reason: Anx's existing Overlay fallback wraps the `InAppWebView` in `Offstage(offstage: true)`, which means Flutter never lays it out — so the native WebView2 host never starts. The first crash never surfaced because no rendering happened in the first place; on the second attempt nothing happened at all.

Fix attempt #2 (Overlay path): parser was made to manage its own `OverlayEntry` (`Positioned(left: -10, top: -10, width: 1, height: 1)` + `IgnorePointer(Opacity(0.0, ...))`), so Flutter actually lays the WebView out and the native WebView2 initialises. With this in place the second WebView2 instance came up cleanly **but** still crashed natively the moment it loaded `paginator.js` — same crash pattern as run #1. Two parallel WebView2 hosts in the same process, both running the foliate-js paginator, are not stable on Windows.

Fix #3 (final): drop WebView from the parsing slice entirely. New shared `lib/service/pipeline/book_file_parser.dart` parses both formats in pure Dart:

- FB2 → `package:xml` walk over `<body>` / nested `<section>` elements; titles from `<title><p>...</p></title>`, content from sibling `<p>` text. Tiny built-in cp1251 lookup table for legacy encoding (FB2 spec allows it; modern files are UTF-8).
- EPUB → `package:epub_decoder` resolves `META-INF/container.xml` → `.opf` → spine; per spine item the XHTML is parsed with `package:html` (`<h1>`/`<h2>`/`<title>` for chapter heading, all `<p>`/`<div>`/`<li>` text for body). Hand-rolled spine extraction was dropped in favour of the package — fewer edge cases.
- `isParseableBookFormat(...)` moved to the new file; both source and reference parsers re-import it from there.
- `xml` and `epub_decoder` added as direct dependencies in `pubspec.yaml`.

The same Dart pipeline is now used for the **original** book parsing too. `ChapterParserService.parseBookIfNeeded` no longer takes a TOC + JS callback — it takes a `File` and runs `BookFileParser` + `ChapterMerger` itself. The trigger in `epub_player.dart` moved from the foliate-js `onSetToc` JavaScript handler to `initState` (`Future.microtask(_maybeStartChapterParsing)`), so parsing kicks off immediately when the reader opens, independent of WebView readiness.

Net effect: no WebView is involved in any chapter-extraction path. Two parallel WebView2 hosts on Windows is no longer a failure mode. EPUB / FB2 are parsed deterministically in tens to hundreds of ms.

This requires a full `flutter run` restart (not hot reload) because `pubspec.yaml` changed.

## 2026-05-08 — Iteration 1: discovery + GlossaryTerm slice (uncommitted)

Onboarding pass on both codebases (Anx-derived AIBookReader and the read-only Python reference at `D:\Projects\NovelTranslator`). Authored `CLAUDE.md`, `tasks/migration_plan.md`, `tasks/active_context.md`, `docs/migration-map.md`.

Implemented the GlossaryTerm vertical slice end-to-end:

- `lib/models/glossary_term.dart` — synthetic-id model; `(book_id, term_source)` unique.
- `lib/dao/glossary_term_dao.dart` — DAO mirroring `BookNoteDao`, with upsert semantics.
- `lib/dao/database.dart` — DB version bumped 7 → 8, new `case 7:` migration creates `tb_glossary_terms` + `idx_glossary_book_id`.
- `lib/providers/glossary.dart` — `@riverpod class Glossary` parameterized on `bookId`.

Verified `flutter pub get` / `dart run build_runner build` clean, `flutter analyze` clean on the touched files, and the app launches on the Samsung SM S721B (id `R5CY604D5BV`). No UI yet — the slice exists only to confirm Anx's architecture cleanly absorbs new pipeline tables.

Working tree left dirty per user instruction; agent does not run write-side git ops.

## 2026-05-09 — Iteration 2: chapter tables + ChapterStatus (uncommitted)

Second pipeline-table slice. `tb_source_chapters` and `tb_target_chapters` are now part of the schema, with the same shape as the Python `SourceChapter` / `TargetChapter` plus a `book_id` foreign-key column (one SQLite database, many books).

- `lib/models/chapter_status.dart` — Dart enum mirroring Python `ChapterStatus` (only the values still used by the active pipeline: `newly`, `parsed`, `translated`, `analyzed`; legacy `cleaned` / `mined` not ported because the steps that produced them are deleted upstream).
- `lib/models/source_chapter.dart`, `lib/models/target_chapter.dart` — final-field models, `toMap` + `fromDb`, identical pattern to `GlossaryTerm`. Target carries an explicit `source_chapter_id` FK so reordering on the source side cannot silently break alignment.
- `lib/dao/source_chapter_dao.dart`, `lib/dao/target_chapter_dao.dart` — `BaseDao` subclasses with upsert (`save`), `selectByBookId`, `selectByStatus`, `updateStatus`, deletes.
- `lib/dao/database.dart` — DB version bumped 8 → 9; new `case 8:` migration creates both tables with their unique constraints, FK on target → source (ON DELETE CASCADE), and `(book_id)` + `(book_id, status)` indexes on each.
- `lib/providers/chapters.dart` — `@riverpod class SourceChapters` and `TargetChapters`, both parameterized on `bookId`. `chapters.g.dart` regenerated.

Verified: `dart run build_runner build --delete-conflicting-outputs` clean, `flutter analyze` clean on the seven touched files, debug APK builds, installs on the Samsung SM S721B, schema confirmed by pulling `app_database.db` and reading it: `user_version=9`, both new tables present with the expected `CREATE TABLE` SQL and four chapter-related indexes.

Known issue: on a fresh install (case 0 → 9), the upstream Anx `case 3:` migration logs an unhandled `Bad state: This can happen if an inner synchronized block is spawned outside the block it was started from` because it calls `bookDao.selectBooks().then(...)` while `onCreate` is still holding the database lock. This is pre-existing upstream code, fires only on first install (incremental 8 → 9 is unaffected), the schema commits correctly, and the app continues running. Out of scope for iteration 2.

## 2026-05-09 — Iteration 3: chapter parser on first book open (uncommitted)

Iteration 3 was rescoped from "translation prompts + single-chapter manual translate" to "first-open chapter parser". Reason: without rows in `tb_source_chapters`, the translator iteration has no real input to work on and would have to invent a paste-in dev surface. Building the parser first means later iterations operate on real data and the user gets the canonical NT-style table populated automatically.

What landed:

- `lib/providers/chapter_parsing.dart` — Riverpod provider parameterized on `bookId`, sealed-class state `ChapterParsingState` (`Idle | Running(done,total) | Done(total) | Failed(error,done,total)`).
- `lib/service/pipeline/chapter_parser_service.dart` — new namespace `lib/service/pipeline/`. `ChapterParserService.parseBookIfNeeded(bookId, toc, fetchChapterByHref, onProgress)` flattens the foliate-js TOC depth-first, fetches plain-text content per `href`, and writes one `SourceChapter` row (status `parsed`) per item. Idempotent: skips when `countByBookId(bookId) > 0`. Decoupled from Riverpod and from the WebView so a future test or Isolate variant can drive it directly. Format gate `isParseableBookFormat()` admits only `.epub` / `.fb2` for this iteration; other formats are logged and skipped.
- `lib/widgets/reading_page/chapter_parsing_indicator.dart` — compact `Парсинг глав: X / Y` chip with a determinate spinner. Renders only while `Running` or `Failed`. Embedded at the top of the reader drawer in `lib/page/reading_page.dart` so it appears the moment the user pulls up the TOC.
- `lib/page/book_player/epub_player.dart` — in the `onSetToc` JS handler (which foliate-js fires once it has parsed the book), the new `_maybeStartChapterParsing(toc)` runs on a microtask. Guarded by `_chapterParsingTriggered` so a manual `refreshToc()` later does not relaunch the pass. Outcome dispatched onto `chapterParsingProvider` notifier.

Verified: `dart run build_runner build --delete-conflicting-outputs` clean (~1m, generates `chapter_parsing.g.dart`); `flutter analyze` clean on all five touched / new files. Two pre-existing `use_build_context_synchronously` info-warnings in `reading_page.dart` (lines 711, 715, in the unchanged `IconButton(Icons.copy)` AppBar block) are not introduced by this iteration.

Not in this slice (deferred): translation prompts and translator service (now Iteration 4); resumability of partially-parsed books (current behavior: if the user closes the reader mid-parse, the rows that already landed stay; subsequent opens do nothing because `countByBookId > 0`); MOBI / AZW3 / TXT / PDF parsing; Isolate / foreground service.

Working tree left dirty per user instruction; agent does not run write-side git ops.
