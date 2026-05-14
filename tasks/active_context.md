# Active Context

## Current Focus — **Term extraction fixes**

The Discovery → LLM filter → Pair mining pipeline (iterations 7-8 from `tasks/migration_plan.md`) landed in the previous session. Code compiles and `flutter analyze` is clean, but a skeptical re-review surfaced **8 issues — three HIGH severity** — that need to be addressed before the pipeline is trustworthy on real books.

**The single source of truth for the work to do is [`tasks/term_extraction_fixes.md`](term_extraction_fixes.md). Read it before touching any term-extraction code.**

Key shortcuts:
- HIGH: connector-chain bug, prefix-only emission bug, missing min-frequency pre-filter, no real cancellation in Stage A isolate (`compute()` is atomic).
- MEDIUM: sentence-initial guard too aggressive, dispersion runs before clustering, LLM prompts see ISO codes instead of English names.
- LOW: `firstChapterId` after cluster merge, `wordCount` includes connectors.

Each issue has concrete file:line and proposed fix in the followup task file.

## What landed in the previous session (uncommitted)

Term-extraction pipeline (Discovery + LLM filter + Pair mining). New files in:
- `lib/dao/`: `term_candidate_dao.dart`, `term_candidate_occurrence_dao.dart`, `glossary_term_variant_dao.dart`.
- `lib/models/`: `term_candidate.dart`, `term_candidate_occurrence.dart`, `glossary_term_variant.dart`, `candidate_status.dart`, `candidate_type.dart`.
- `lib/service/pipeline/discovery/`: 10 files implementing the 6-stage Stage A pipeline (tokenizer, language detector, stopwords loader, candidate generator, C-value scorer, dispersion scorer, morphology clusterer, substring penalizer, isolate orchestrator, service).
- `lib/service/pipeline/filter/term_filter_service.dart` — Stage B.
- `lib/service/pipeline/mining/`: chapter selector, postfilter, mining service.
- `lib/service/pipeline/term_extraction_task_handler.dart` — minimal no-op foreground task handler (see Fix-out-of-scope in the followup).
- `lib/service/ai/json_response.dart`, `lib/service/ai/ai_generate_once.dart` — tolerant JSON parser + Future-shaped wrapper around `aiGenerateStream`.
- `lib/providers/term_extraction.dart` — Riverpod controller with sealed state.
- `lib/widgets/book_detail/term_extraction_card.dart` — UI card with three progress bars; mounted in `buildMoreDetail()` of `book_detail.dart`.

Changes to existing files:
- DB v10 → v11 in `lib/dao/database.dart`. New tables `tb_term_candidates`, `tb_term_candidate_occurrences`, `tb_glossary_term_variants` + 5 indexes.
- `lib/enums/ai_prompts.dart`: added `candidateFilter` and `candidateMining` cases with default prompts.
- `lib/service/ai/prompt_generate.dart`: added `generatePromptCandidateFilter` and `generatePromptCandidateMining`.
- `lib/main.dart`: `FlutterForegroundTask.initCommunicationPort()` at startup.
- `pubspec.yaml`: `unorm_dart`, `snowball_stemmer`, `flutter_foreground_task` deps; `assets/data/` registered.
- `android/app/src/main/AndroidManifest.xml`: `FOREGROUND_SERVICE_DATA_SYNC` and `POST_NOTIFICATIONS` permissions.
- `assets/data/stopwords-iso.json` (~200 KB, 57 languages, MIT) + `STOPWORDS_LICENSE.md`.

Plan / research the implementation was based on:
- `C:\Users\Admin\.claude\plans\starry-popping-clock.md` — algorithmic plan and pipeline diagram.
- `C:\Users\Admin\.claude\plans\starry-popping-clock-agent-ad6be62dd79c96854.md` — research that selected C-value + truncated YAKE + single-pass clustering + Gries DP + Snowball stemmer.

## Verification done in the previous session

- `dart run build_runner build --delete-conflicting-outputs` — clean (453 outputs).
- `flutter analyze lib/` — 42 info-level warnings, all pre-existing in unrelated files; **0 errors / 0 warnings in any new or modified file**.
- **No on-device run yet.** The first realistic test will need a book with translated `tb_target_chapters` filled in. The pipeline is gated by Iteration 4 (single-chapter translate) which is still TODO — so a manual SQL pre-seed will be needed, or wait for Iteration 4 to land first.

## Known limitations to document later

(Carried over from the previous focus, still applies.)

- **No resumability of partial parses** — chapter parser is idempotent on book level, not chapter level. Closing the reader mid-parse skips remaining chapters.
- **EPUB / FB2 only** for source parsing.
- **Books parsed before v10** only get `chapter_number` lazily backfilled — sub-chapter merge is not retroactive.
- **Chinese numeral chapters** (`第一章`) detected as chapters but `chapter_number` stays NULL.
- **Soft-deleting a book** does not cascade to reference translations, candidates, glossary, variants — same project-wide gap.

## Up next (after term-extraction fixes)

- Commit cadence decision for iterations 1-8 (all still uncommitted).
- Iteration 9: glossary RAG-lite for the translator. The pipeline now produces a clean glossary; the next step is feeding it into Iteration 4's translator prompt as constraint terminology.
- Unit tests for the Stage A algorithms (separate slice — see `tasks/term_extraction_fixes.md` "Out of scope").

## Pre-existing notes / things to watch

- The reentrant-`onUpgrade` bug in upstream Anx `case 3:` (logs `Bad state` on fresh install, schema commits OK) is still unfixed and out of scope.
- Plugins `haptic_feedback` and `in_app_purchase_android` still want `compileSdk = 36`; project compiles fine against 35.

---

For prior iterations (1: GlossaryTerm; 2: chapter tables + `ChapterStatus`; 3: first-open chapter parser; 3.5: reference translations + alignment) see `tasks/changelog.md`.
