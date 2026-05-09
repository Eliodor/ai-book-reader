# Active Context

## Current Focus

**Iteration 3 — first-open chapter parser — DONE (uncommitted).**

Iterations 1 (`GlossaryTerm`) and 2 (chapter tables + `ChapterStatus`) are still uncommitted in the working tree from the prior session; Iteration 3 layers on top of them. The migration plan was rescoped: the original Iteration 3 ("translation prompts + single-chapter manual translate") is now Iteration 4. Reason: building the parser first lets later iterations work on real data instead of paste-in fixtures.

## What landed in this session (in working tree, uncommitted)

- `lib/providers/chapter_parsing.dart` — Riverpod provider, parameterized on `bookId`, sealed-class state `ChapterParsingIdle | Running(done,total) | Done(total) | Failed(error,done,total)`. `chapter_parsing.g.dart` generated.
- `lib/service/pipeline/chapter_parser_service.dart` — new pipeline namespace. `ChapterParserService.parseBookIfNeeded(...)` is idempotent (skips when `sourceChapterDao.countByBookId > 0`), DFS-flattens the foliate-js TOC, fetches plain-text content per `href`, writes one `SourceChapter(status: parsed)` per item. Returns a sealed `ChapterParsingOutcome` so the caller decides what to render. Sibling helper `isParseableBookFormat(filePath)` gates on `.epub` / `.fb2`.
- `lib/widgets/reading_page/chapter_parsing_indicator.dart` — compact "Парсинг глав: X / Y" chip with a determinate spinner. Renders only when state is `Running` or `Failed`.
- `lib/page/book_player/epub_player.dart` — new `_maybeStartChapterParsing(toc)` is wired into the existing `onSetToc` JS handler (foliate-js fires it after parsing the book). Guarded by `_chapterParsingTriggered` against multiple invocations from a later `refreshToc()`. Service runs on a microtask; outcome dispatched onto `chapterParsingProvider`.
- `lib/page/reading_page.dart` — embedded `ChapterParsingIndicator(bookId)` at the top of the reader drawer, above `TocWidget`.

## Verification done in this session

- `dart run build_runner build --delete-conflicting-outputs` — succeeded after ~1m; generated `chapter_parsing.g.dart`.
- `flutter analyze lib/providers/chapter_parsing.dart lib/service/pipeline/chapter_parser_service.dart lib/widgets/reading_page/chapter_parsing_indicator.dart lib/page/book_player/epub_player.dart lib/page/reading_page.dart` — clean for this slice. Two pre-existing `use_build_context_synchronously` info-warnings appear in `reading_page.dart` at lines 711 / 715 inside the unchanged `IconButton(Icons.copy)` AppBar block; not introduced here.
- No on-device verification yet (Windows desktop / Samsung phone). Recommended next step before commit: `flutter run -d windows`, open an EPUB, watch the indicator, then on Android `adb shell pm clear …` and reopen to confirm `tb_source_chapters` rows.

## Known limitations to document later

- **No resumability of partial parses.** If the user closes the reader after the parser has saved 12 of 50 chapters, the next open will skip parsing (because `countByBookId > 0`) and leave the remaining 38 chapters unsaved. Acceptable for iteration 3 since translator (iteration 4) will refuse to run until parsing is complete; a follow-up will look at `countByBookId(bookId) < tocLength` to detect partials.
- **EPUB / FB2 only.** TXT / PDF / MOBI / AZW3 are silently skipped (logged via `AnxLog.info`). foliate-js can render them, but the translation pipeline focuses on EPUB/FB2 first.
- **Main-thread parsing.** The parsing pass walks chapters one at a time on the UI thread via `await fetchChapterByHref(href)`. Each call is a JS round-trip into the WebView — actual heavy work happens in foliate-js, not Dart, so this is acceptable for now. A future iteration may wrap this in an Isolate / foreground service (Iteration 6).

## Up next

- **Iteration 4** — translation prompts + single-chapter manual translate. Now has real data: `tb_source_chapters` will be populated for any EPUB/FB2 the user opens. Plan: port `COMPACT_TRANSLATOR_SYSTEM_PROMPT` from `D:\Projects\NovelTranslator\modules\services\prompts\translation.py` into `lib/service/ai/prompt_generate.dart`; build `lib/service/pipeline/translator_service.dart` for one chapter (single LLM call, JSON output, parse `title` + `translation`, ignore `glossary_candidates` for now); bind to a developer-only debug button in `lib/page/settings_page/developer/developer_options_page.dart`. Glossary RAG-lite, genre presets, audit passes — still deferred.
- Decide on commit cadence for iterations 1-3 (still all uncommitted).

## Pre-existing notes / things to watch

- The reentrant-`onUpgrade` bug in upstream Anx `case 3:` (logs a `Bad state` on fresh install but the schema commits correctly) is still unfixed and out of scope for iteration 3.
- Plugins `haptic_feedback` and `in_app_purchase_android` keep warning that they want `compileSdk = 36`; project compiles fine against 35 today.

---

For prior iterations (1: GlossaryTerm slice; 2: chapter tables + `ChapterStatus`) see `tasks/changelog.md`.
