# Changelog

Milestones in the AI Book Reader port. Format: `## YYYY-MM-DD — what shipped`.

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
