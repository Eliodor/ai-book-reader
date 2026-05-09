# Changelog

Milestones in the AI Book Reader port. Format: `## YYYY-MM-DD — what shipped`.

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
