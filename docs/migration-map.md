# Migration Map

Concrete file-to-file mapping from the Python reference repo (`D:\Projects\NovelTranslator\`) to this Dart codebase. Updated as each migration slice ships.

> Snapshot of the Python repo as of **2026-05-08**. The original onboarding brief mentioned legacy steps (`CleanerStep`, `MinerStep`, `NgramAnalyzerStep`, `CandidateFilterStep`) that have been **deleted upstream** (see `D:\Projects\NovelTranslator\tasks\active_context.md` — "Legacy steps deleted: cleaner, old miner, n-gram analyzer, candidate filter."). They are not part of the migration.

## Status legend

- **TODO** — not started.
- **WIP** — partial port in progress.
- **DONE** — landed in `master`.
- **N/A** — explicitly not ported (Anx already covers it, or the concept is being redesigned).

## Models (`core/database/models.py` → `lib/models/` + `lib/dao/database.dart`)

| Python | Dart | Status | Notes |
|---|---|---|---|
| `ChapterStatus` enum | `lib/enums/chapter_status.dart` | TODO | Iteration 2. Mobile may collapse `CLEANED` / `MINED` / `ANALYZED` since cleaner+miner are deleted upstream. |
| `SourceChapter` | `lib/models/source_chapter.dart` + table `tb_source_chapters` | TODO | Iteration 2. Foreign key to `tb_books.id`. |
| `TargetChapter` | `lib/models/target_chapter.dart` + table `tb_target_chapters` | TODO | Iteration 2. Foreign key to `tb_books.id` (book scope) and matches source by `order_index`. |
| `GlossaryTerm` (PK = `term_source`) | `lib/models/glossary_term.dart` + table `tb_glossary_terms` | **WIP — Iteration 1** | This session. On mobile we use a synthetic `INTEGER PRIMARY KEY AUTOINCREMENT` and a `UNIQUE` index on `(book_id, term_source)` so the same word can have different translations across books. |
| `NgramAnalysis` | `lib/models/ngram_analysis.dart` + table `tb_ngrams` | TODO | Whether we keep this on-device at all is open — it's heavy. May only ship as in-Isolate scratch state, not persisted. |
| `TermCandidate` | `lib/models/term_candidate.dart` + table `tb_term_candidates` | TODO | Iteration 7. |
| `TermCandidateOccurrence` | `lib/models/term_candidate_occurrence.dart` + table `tb_term_candidate_occurrences` | TODO | Iteration 7. |
| `ProjectConfig` (singleton settings JSON) | merged into `tb_books` (per-book metadata) — *decision pending* | TODO | Mobile concept of "project" collapses to "book." |

## Data access (`core/database/repository.py` → `lib/dao/`)

| Python | Dart | Status | Notes |
|---|---|---|---|
| `Repository.add_glossary_term`, `get_glossary_terms`, `update_glossary_term`, etc. | `lib/dao/glossary_term_dao.dart` | **WIP — Iteration 1** | Following the `BookNoteDao` template (`lib/dao/book_note.dart`). |
| `Repository.add_source_chapter`, `get_source_chapters_by_status`, etc. | `lib/dao/source_chapter_dao.dart` | TODO | Iteration 2. |
| `Repository.add_target_chapter`, etc. | `lib/dao/target_chapter_dao.dart` | TODO | Iteration 2. |
| `Repository.add_term_candidate`, `promote_candidates_to_glossary`, etc. | `lib/dao/term_candidate_dao.dart` | TODO | Iteration 7-8. |

The Repository god-class is intentionally *not* ported as a single class — Dart breaks it into one DAO per table.

## LLM access

| Python | Dart | Status | Notes |
|---|---|---|---|
| `modules/llm_client/clients.py`, `factory.py`, `interfaces.py`, `options.py` | `lib/service/ai/ai_services.dart`, `ai_model_service.dart`, `langchain_runner.dart`, `langchain_registry.dart` | N/A | Anx already wraps `langchain_dart` (OpenAI / Anthropic / Gemini / DeepSeek / OpenRouter). Reuse it. |
| `config/llm_profiles.py` (per-profile concurrency, retries, max_tokens) | small Dart helper around `langchain_runner` (deferred) | TODO | Add when translator service starts hitting real LLMs at scale. |

## Pipeline orchestration

| Python | Dart | Status | Notes |
|---|---|---|---|
| `core/context/execution_context.py` | Riverpod `Ref` + dedicated providers in `lib/providers/` | N/A | Riverpod replaces the context object. Pipeline services receive `Ref` (or read-only deps) directly. |
| `steps/base_step.py` | `lib/service/pipeline/base_step.dart` | TODO | Iteration 3. Abstract class with `Future<void> execute()`. May add cancel / progress interfaces. |

## Pipeline steps

| Python step | Dart service | Status | Notes |
|---|---|---|---|
| `steps/parser_step.py` (FB2/EPUB import + paired EN/RU) | extend `lib/service/book.dart` (Anx's importer) | TODO | Iteration 4. Don't replace Anx's import — extend it to populate `tb_source_chapters` when a book is opened in translation mode. |
| `steps/translator_step.py` | `lib/service/pipeline/translator_service.dart` | TODO | Iteration 3 (single chapter) → Iteration 6 (Isolate + parallel + foreground service). Largest port. |
| `steps/candidate_discovery_step.py` | `lib/service/pipeline/candidate_discovery_service.dart` | TODO | Iteration 7. Pure regex + N-gram CPU work — must run in Isolate. |
| `steps/candidate_guided_miner_step.py` | `lib/service/pipeline/guided_miner_service.dart` | TODO | Iteration 8. |
| `steps/fb2_export_step.py` | `lib/service/export/fb2_export_service.dart` | TODO | Iteration 9. Output via `share_plus` share-sheet on mobile. |
| ~~`steps/cleaner_step.py`~~ | — | N/A — deleted upstream | |
| ~~`steps/miner_step.py`~~ | — | N/A — deleted upstream | |
| ~~`steps/ngram_analyzer_step.py`~~ | — | N/A — deleted upstream | |
| ~~`steps/candidate_filter_step.py`~~ | — | N/A — deleted upstream | |

## Prompts

| Python | Dart | Status | Notes |
|---|---|---|---|
| `modules/services/prompts/translation.py` | `lib/service/ai/prompt_generate.dart::generatePromptTranslate` (already exists, may need extending) + new `generatePromptFullTextTranslate` (already exists) + audit prompts | TODO | Iteration 3. Port `TRANSLATOR_SYSTEM_PROMPT`, `TRANSLATOR_USER_PROMPT_TEMPLATE`, `AUDIT_GLOSSARY_*`, `AUDIT_FIDELITY_*`. Keep wording close to original. |
| `modules/services/prompts/candidate_mining.py` | new `generatePromptCandidateMining` etc. | TODO | Iteration 8. |
| `modules/services/prompts/candidate_filtering.py` | new `generatePromptCandidateFilter` | TODO | Iteration 7-8. |
| `modules/services/prompts/mining.py` | (decide whether still needed once candidate-guided pipeline lands in Dart) | TODO | Possibly N/A — original `MinerStep` is deleted; only the candidate-guided variant stays. |
| `modules/services/prompts/structure.py` | as needed | TODO | Iteration 4 (parsing). |
| `modules/services/prompts/genre_presets.py` | new Dart `enum GenrePreset` + accompanying constants | TODO | Iteration 3. |

## Helpers / small modules

| Python | Dart | Status | Notes |
|---|---|---|---|
| `modules/services/glossary_matcher.py` | `lib/service/pipeline/glossary_matcher.dart` | TODO | Iteration 3. Token-index lookup; pure Dart. |
| `modules/ngram_optimizer/optimizer.py` | `lib/service/pipeline/ngram_service.dart` | TODO | Iteration 7. Pure CPU — runs inside Isolate. |
| `utils/chapter_number.py` (language-agnostic chapter number extractor) | `lib/utils/chapter_number.dart` | TODO | Iteration 4. |
| `utils/llm_errors.py` (transient 503/429/UNAVAILABLE detection) | `lib/utils/llm_errors.dart` | TODO | Iteration 6 (when adding retries). |
| `utils/bench_translation_modes.py` | maybe `test/` or dev-only screen | TODO | Defer indefinitely. |

## UI

| Python | Dart | Status | Notes |
|---|---|---|---|
| `interactive.py` (CLI menus) | new screens in `lib/page/` | TODO | Iteration 5+. Not a port — a redesign. Per-book "translate" tab, step-run buttons, progress, glossary editor accessed by long-press in the reader. |

## Foliate / WebView integration

| Anx code | Dart change | Status | Notes |
|---|---|---|---|
| `lib/page/book_player/epub_player.dart:864` `translateText` handler | Re-route to our on-device pipeline (`translator_service.dart`) for the open book | TODO | Iteration 11. Currently delegates to `Prefs().fullTextTranslateService.provider.translateTextOnly(...)`. Will swap to LLM-pipeline-backed translation. |
| `assets/foliate-js/src/translator.js` | No structural change needed — keep modes (`OFF`, `TRANSLATION_ONLY`, `ORIGINAL_ONLY`, `BILINGUAL`) and the `IntersectionObserver` strategy. | DONE (as-is) | |
