# Active Context

## Current Focus

**Iteration 3.5 — reference translations + chapter-number alignment — DONE (uncommitted).**

Iterations 1-3 are still uncommitted in the working tree from prior sessions; this slice layers on top. Originally planned as part of a later iteration, was pulled forward at user request to unblock the paired-glossary work.

Iterations 1 (`GlossaryTerm`), 2 (chapter tables + `ChapterStatus`), 3 (first-open chapter parser) — see `tasks/changelog.md`.

## What landed in this session (in working tree, uncommitted)

Reference translations slice — full file list in `tasks/changelog.md` under the 2026-05-10 entry. Highlights:

- DB v9 → v10. New tables `tb_reference_translations`, `tb_reference_chapters`. New `chapter_number` column on `tb_source_chapters` for alignment.
- New helpers `lib/utils/chapter_number_extractor.dart` and `lib/service/pipeline/chapter_merger.dart` — pure-Dart, regex-only, no LLM. Detector reuses `getDefaultChapterSplitRule()` from `lib/models/chapter_split_presets.dart` for universal coverage (中/EN/Vol/Book).
- Existing `ChapterParserService` extended: now runs every fetched book through `ChapterMerger` before persisting. Backfill method for v9-era rows.
- New `ReferenceTranslationParserService` — separate `AnxHeadlessWebView` instance, `importing=false`, stub handlers for `onLoadEnd` / `renderAnnotations`.
- New `referenceTranslationsProvider(bookId)` — Riverpod, serialised parsing queue, status mirroring `tb_reference_translations.parsing_status`.
- New `ReferenceTranslationsCard` widget mounted in `buildMoreDetail()` of `book_detail.dart`. Supports multi-select FilePicker + desktop drag-and-drop. Per-part delete with confirmation, file-on-disk also cleaned.
- 13 l10n keys added to `app_en.arb`; `flutter gen-l10n` regenerated.

## Verification done in this session

- `dart run build_runner build --delete-conflicting-outputs` — clean; generated `reference_translations.g.dart`.
- `flutter gen-l10n` — clean across all 14 locale files; non-English locales fall back to English for the new keys until translated.
- `flutter analyze` — clean for every file touched in this slice. Pre-existing info-warnings in unrelated files unchanged.
- No on-device verification yet. Recommended next step before commit: `flutter run -d windows`, open the detail page of an EPUB book, drop an `.epub` / `.fb2` part on the card, and watch it move from `parsing` to `parsed`. Then run the alignment SQL `SELECT s.title, r.title FROM tb_source_chapters s JOIN tb_reference_chapters r ON r.book_id = s.book_id AND r.chapter_number = s.chapter_number WHERE s.book_id = ?` to confirm the join.

## Known limitations to document later

- **No resumability of partial parses.** If the user closes the reader after the parser has saved 12 of 50 chapters, the next open will skip parsing (because `countByBookId > 0`) and leave the remaining 38 chapters unsaved. Acceptable for iteration 3 since translator (iteration 4) will refuse to run until parsing is complete; a follow-up will look at `countByBookId(bookId) < tocLength` to detect partials.
- **EPUB / FB2 only.** TXT / PDF / MOBI / AZW3 are silently skipped (logged via `AnxLog.info`). foliate-js can render them, but the translation pipeline focuses on EPUB/FB2 first.
- **Main-thread parsing.** The parsing pass walks chapters one at a time on the UI thread via `await fetchChapterByHref(href)`. Each call is a JS round-trip into the WebView — actual heavy work happens in foliate-js, not Dart, so this is acceptable for now. A future iteration may wrap this in an Isolate / foreground service (Iteration 6).
- **Books parsed before v10** only get `chapter_number` lazily back-filled — sub-chapter merge is **not** retroactive. To re-parse cleanly, force a wipe (`adb shell pm clear …` on Android, or delete the local DB) and reopen.
- **Chinese numeral chapters** (`第一章`) are detected by the chapter rule but their numeric ID stays `NULL` (no `一二三 → 1` converter yet). Such chapters are not aligned across original ↔ reference.
- **Soft-deleting a book** does not cascade-clean `tb_reference_translations`, `tb_reference_chapters`, or the copied files on disk (same gap exists for notes / glossary / source chapters; project-wide fix is its own future iteration).
- **No Web drag-and-drop.** `desktop_drop` is desktop-only; the file picker still works on Web/mobile.

## Up next

- **Runtime verification** of the reference-translations card on Windows desktop and the Samsung phone (drop / pick / parse / delete / re-add). Update this doc with results.
- **Iteration 4** — translation prompts + single-chapter manual translate. Plan: port `COMPACT_TRANSLATOR_SYSTEM_PROMPT` from `D:\Projects\NovelTranslator\modules\services\prompts\translation.py` into `lib/service/ai/prompt_generate.dart`; build `lib/service/pipeline/translator_service.dart` for one chapter (single LLM call, JSON output, parse `title` + `translation`, ignore `glossary_candidates` for now); bind to a developer-only debug button in `lib/page/settings_page/developer/developer_options_page.dart`. Glossary RAG-lite, genre presets, audit passes — still deferred.
- Decide on commit cadence for iterations 1-3.5 (still all uncommitted).

## Pre-existing notes / things to watch

- The reentrant-`onUpgrade` bug in upstream Anx `case 3:` (logs a `Bad state` on fresh install but the schema commits correctly) is still unfixed and out of scope for iteration 3.
- Plugins `haptic_feedback` and `in_app_purchase_android` keep warning that they want `compileSdk = 36`; project compiles fine against 35 today.

---

For prior iterations (1: GlossaryTerm slice; 2: chapter tables + `ChapterStatus`) see `tasks/changelog.md`.
