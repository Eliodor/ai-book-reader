# Active Context

## Current Focus — **Term extraction fixes — code landed (incl. review follow-ups), awaiting verification**

The Discovery → LLM filter → Pair mining pipeline (iterations 7-8 from `tasks/migration_plan.md`) landed two sessions ago. A skeptical re-review surfaced 9 issues, all 9 landed on 2026-05-15. A second multi-source review on 2026-05-17 (manual + `simplify` 3 sub-agents + `code-review-excellence`) surfaced a deeper correctness bug plus a batch of efficiency / cleanup items — **the correctness bug and the high-value cleanups are now also in source, uncommitted, `flutter analyze` clean across all 18 touched files.**

**The single source of truth is still [`tasks/term_extraction_fixes.md`](term_extraction_fixes.md).** Two sections to read:
- “Implementation log (2026-05-15)” — the original 9 fixes.
- “Follow-ups discovered during multi-source review (2026-05-17)” — what the review caught, what landed (✅), what is deferred and why (incl. the AI runner re-entrancy blocker for parallel mining).

### Files touched (uncommitted, on `master`)

Original 9 fixes (2026-05-15):
- `lib/service/pipeline/discovery/candidate_generator.dart` — Fixes 1, 2, 5, 9 (+ review trivials).
- `lib/service/pipeline/discovery/cvalue_scorer.dart` — Fix 4 (async + cancel cadence) + super-candidate dedup via `Set<String>`.
- `lib/service/pipeline/discovery/morphology_clusterer.dart` — Fix 8 + chapterFrequencies merge.
- `lib/service/pipeline/discovery/term_discovery_isolate.dart` — Fixes 3, 4, 6. Substantial rewrite. Drops `buildChapterCounts`.
- `lib/service/pipeline/discovery/term_discovery_service.dart` — Fix 4. `Isolate.spawn` + cancel `SendPort`. `DiscoveryCancelled` outcome.
- `lib/service/ai/locale_names.dart` — **new file** (Fix 7).
- `lib/service/pipeline/mining/term_mining_service.dart` — Fix 7 + review fixes (parallel-mining plumbing, bulk variant upsert, retry helper).
- `lib/providers/term_extraction.dart` — Fix 4. `TermExtractionCancelled` state + Filter/Mining cancelled routing.
- `lib/widgets/book_detail/term_extraction_card.dart` — small UI tweak so the cancelled state shows “Отменено пользователем”.

Added in the 2026-05-17 review pass:
- `lib/service/pipeline/discovery/raw_models.dart` — `Map<int,int> chapterFrequencies` field; `superCandidateIndices: Set<int>(hashCode)` → `superCandidateKeys: Set<String>`.
- `lib/service/pipeline/discovery/dispersion_scorer.dart` — reads `chapterFrequencies` directly, no fallback approximation; `buildChapterCounts` / `ChapterCount` deleted.
- `lib/service/pipeline/filter/term_filter_service.dart` — `FilterCancelled` outcome; uses `retryOnTransient`; bulk-snippet query.
- `lib/service/pipeline/mining/mining_chapter_selector.dart` — removed `bestAllCount` no-op.
- `lib/dao/term_candidate_occurrence_dao.dart` — new `selectFirstByCandidateIds(List<int>)`.
- `lib/dao/glossary_term_variant_dao.dart` — new `bulkUpsertVariants(List<VariantUpsert>)` + `VariantUpsert` DTO.
- `lib/service/ai/ai_retry.dart` — **new file**. `retryOnTransient<T>` + `isTransientAiError(Object)`.

Added in the 2026-05-17 end-of-day non-concurrency bug pass:
- `lib/dao/database.dart` — **DB v11 → v12**, new `tb_mining_progress` table + index in additive `case 11:` block.
- `lib/dao/mining_progress_dao.dart` — **new file**. `selectMinedChapterIds`, `markMined`, `deleteByBookId`.
- `lib/service/pipeline/mining/term_mining_service.dart` — resumability wiring (skip already-mined chapters via `MiningProgressDao`, mark on success).
- `lib/providers/term_extraction.dart` — `reset()` also clears `miningProgressDao.deleteByBookId`. UI notifications switched to Ukrainian.
- `lib/service/ai/json_response.dart` — peels up to two fence layers.
- `lib/service/pipeline/filter/term_filter_service.dart` — `_batchSize` resets per `filterIfNeeded` run (no longer leaks across books).
- `lib/service/pipeline/mining/mining_postfilter.dart` — 4 regexes hoisted to `static final`.
- `lib/service/pipeline/discovery/cvalue_scorer.dart` — pre-computed padded normalized source removes per-probe allocation.
- `lib/widgets/book_detail/term_extraction_card.dart` — UI strings switched to Ukrainian.
- `lib/enums/ai_prompts.dart` — mining prompt morphology example switched from Russian to Ukrainian.

### What still needs to happen before this iteration can be archived

1. **On-device verification** against the acceptance criteria in `term_extraction_fixes.md` (Master/Crimson/Hall sub-spans, Ukrainian morphology cluster, ≤ 3 s cancel, ≤ 35 LLM calls in Stage B, dictionary-form translations in Stage C). The pipeline still requires a book with translated `tb_target_chapters` rows; Iteration 4 (single-chapter translate) hasn’t landed, so the first run still needs a manual SQL pre-seed.
2. **Commit decision** for iterations 1-8 + these fixes (still all uncommitted; see § “Up next”).
3. After verification + commit: changelog entry; delete or archive `term_extraction_fixes.md`.

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

### Deferred items (full list in `term_extraction_fixes.md` § "Follow-ups discovered during multi-source review")

Concurrency cluster — held for a separate session per user instruction:

1. **`CancelableLangchainRunner` re-entrancy** — `lib/service/ai/langchain_runner.dart:10` holds one `_subscription` at module scope, which is why mining `concurrency` had to stay at `1`. Returning `(Stream<String>, Cancelable)` from `stream()` unblocks a ~3-5× wall-clock win on Stage C.
2. **Real foreground task isolate** — Stage B/C still run on the main isolate. Move them into the `TaskHandler` once item (1) lands so cancel/progress works across the isolate boundary.
3. **Cross-service `PipelineCancellationToken`** — replaces three ad-hoc `_cancelled` flags.

Non-concurrency leftovers:

4. Stage strings + candidate type strings → enums (~stylistic but kills `default:` fallthroughs that hide typos).
5. `_DiscoveryCancelledException` and mixed typed/untyped isolate messages — clean up once the cancellation token lands.
6. Memory peak measurement on a low-end Android for `_emitGroup` × O(C²) before prefilter.
7. **Battery optimisation request** on Android — call `FlutterForegroundTask.requestIgnoreBatteryOptimization()` so doze-mode doesn't kill long Stage C runs.
8. **`tb_glossary_term_variants` review UI** — variants are persisted but never surfaced; a "Review alternatives" sheet would let the user override a vote.
9. **Unit tests for Stage A** — C-value, single-pass cluster, postfilter, JSON parser have no coverage. Split into `tasks/term_extraction_tests.md`.

## Pre-existing notes / things to watch

- The reentrant-`onUpgrade` bug in upstream Anx `case 3:` (logs `Bad state` on fresh install, schema commits OK) is still unfixed and out of scope.
- Plugins `haptic_feedback` and `in_app_purchase_android` still want `compileSdk = 36`; project compiles fine against 35.

---

For prior iterations (1: GlossaryTerm; 2: chapter tables + `ChapterStatus`; 3: first-open chapter parser; 3.5: reference translations + alignment) see `tasks/changelog.md`.
