# Active Context

## Current Focus — **Stage A scoring & cutoff tuning — code landed, awaiting on-device verification**

After landing the full Discovery + LLM filter + Mining pipeline and a round of correctness fixes, the active loop has been **measuring and tuning Stage A** against ground-truth glossaries via the standalone benchmark (no device, no UI, no LLM). The single source of truth for the benchmark workflow remains [`tasks/term_extraction_benchmark.md`](term_extraction_benchmark.md).

The current iteration is in [`tasks/stage_a_tuning.md`](stage_a_tuning.md) — read that file for everything below in detail. **All work in that file is uncommitted, on `master`.**

Headline numbers (Solo Leveling Yen Press 8-volume EN):

| | Pool size | strict vs Wiki | loose vs Wiki | strict vs LLM | loose vs LLM |
|---|---:|---:|---:|---:|---:|
| Baseline (pre-tuning, top-N=1515 cap) | 1 515 | 61.2% | 87.4% | 35.6% | 78.7% |
| **Current (score > 0, no top-N cap)** | **4 592** | **73.2%** | **96.7%** | **57.7%** | **94.0%** |

`vs LLM` is against an 873-term LLM-extracted glossary (8 parallel agents, one per Yen Press volume, then deduped via case+hyphen+plural folding). Both glossaries live under `benchmarks/term_extraction/data/solo-leveling/`.

## What's landed and pushed (master)

Mapped to commits, oldest → newest:

| Commit | Iteration | Headline |
|---|---|---|
| `05dab3ab` | 1 | GlossaryTerm slice + initial CLAUDE.md / memory / tasks. |
| `cf1010f7` | 2 | Chapter tables (`tb_source_chapters`, `tb_target_chapters`) + `ChapterStatus` + Windows ATL / C5054 build fix. |
| `5afbacbf` | 3 | First-open chapter parser (foliate-js TOC walk → rows in `tb_source_chapters`). |
| `c277b457` | 3.5 | Reference translations + chapters, chapter-number alignment, pure-Dart EPUB/FB2 parser (no WebView). |
| `e7a991f2` | 7-8 | Full pipeline: Discovery (6-etap isolate) + Filter (LLM batched) + Mining (per-chapter, voting via `tb_glossary_term_variants`). |
| `e7ecc07c` | 7-8 fixes | All 9 fixes from `term_extraction_fixes.md` + multi-source review fixes + DB v12 `tb_mining_progress` for Stage C resumability. |
| `0ae89a0f` | Benchmark v1 | Standalone benchmark crate, ground truth from Solo Leveling fandom, adaptive topN. |
| `42c8896f` | Stage A upgrade | LLM normalization output, grouping + normalization tools, latest Stage A iteration. |

**Uncommitted on `master` (this iteration — see `tasks/stage_a_tuning.md`):**

- `lib/service/pipeline/discovery/text_artifacts.dart` (new) — `cleanTermArtifacts`: strips `.,!?;:…` and collapses `>2` identical-char runs.
- `candidate_generator.dart` — calls `cleanTermArtifacts`; adds stopword-guard in `_ingestQuotedSpans` (first/last/≥50% test).
- `cvalue_scorer.dart` — type boost (`proper_name × 1.4`, `title/organization × 1.3`, `technique × 1.2`).
- `substring_penalizer.dart` — `0.6` softer multiplier for frequent (`freq ≥ 10`) `proper_name` candidates.
- `dispersion_scorer.dart` — drops `topK` cap; runs Gries DP on every candidate; adds `×1.2` recency bonus for first-third-of-book + `freq ≥ 5`.
- `term_discovery_isolate.dart` — `DiscoveryInput.minScore = 0.0`, score-floor cut after sort. Computes `earlyChapterIds` set for recency bonus. **`topN` remains as safety cap.**
- `tokenizer.dart` — `Token.normalizedText` strips trailing `['’ʼ]s` (English possessive). `text` keeps original.
- Benchmark instrument (`benchmarks/term_extraction/`): `lib/term_normalizer.dart`, `tool/normalize_terms.dart`, `tool/normalize_stage_a.dart`, `tool/merge_volume_terms.dart` (all new); `bin/run_benchmark.dart` extended with `--terms-json` and `--ground-truth` flags.

`tasks/term_extraction_fixes.md` and `tasks/stage_a_tuning.md` are the two open iteration docs; the former is historical, the latter is active.

## What still needs to happen

1. **On-device verification of the Stage A tuning** (this iteration). `flutter run -d <device>`, hot-restart, trigger term extraction on a real book, confirm `tb_term_candidates` row count matches benchmark expectation for that book.
2. **Wire `minScore` through `TermDiscoveryService`**. Currently the field exists on `DiscoveryInput` but the service forwards only `topN`. On-device pipeline still runs without the score-floor until this is plumbed. See `tasks/stage_a_tuning.md` § "Open ideas" (3).
3. **Multi-language smoke** of Stage A tuning on a Ukrainian or Russian EPUB — capitalization rules + stopwords path should still light up.
4. **Commit decision** for `tasks/stage_a_tuning.md` work. Once 1–3 land, the iteration can be committed and the doc archived into `changelog.md`.
5. **On-device verification of Stage B + Stage C.** Acceptance criteria in `term_extraction_fixes.md`. Still blocked by Iteration 4 (translator) — no production path to fill `tb_target_chapters` for a test book without manual SQL pre-seed.
6. **Iteration 4 (translator)** per `tasks/migration_plan.md`.
7. **Changelog entries** for iterations 7-8, the fixes, the benchmark, and Stage A tuning — `tasks/changelog.md` currently stops at 2026-05-10 (Iteration 3.5).
8. **Standalone Stage B (LLM filter) benchmark** — analogue to `tool/run_discovery_benchmark.dart`. Listed under "Open ideas" in the benchmark doc.

## Known limitations (carried over)

- **No resumability of partial parses** — chapter parser is idempotent on book level, not chapter level.
- **EPUB / FB2 only** for source parsing.
- **Books parsed before v10** only get `chapter_number` lazily backfilled — sub-chapter merge is not retroactive.
- **Chinese numeral chapters** (`第一章`) detected as chapters but `chapter_number` stays NULL.
- **Soft-deleting a book** does not cascade to reference translations, candidates, glossary, variants.

## Up next (after Stage A iteration plateaus)

- **Iteration 4 — translator** (per migration plan). Port `COMPACT_TRANSLATOR_SYSTEM_PROMPT`, build `translator_service.dart`, dev-only debug button. Unblocks end-to-end pipeline run.
- **Iteration 9 — glossary RAG-lite** for the translator: feed Stage C output into translator prompts as constraint terminology.
- Sub-agent ground-truth extraction (estimated $1-6 / book in LLM cost) — would give per-translation gt without hand-curation. The 8-volume LLM glossary in this iteration is a manual prototype of this idea. See `term_extraction_benchmark.md` § Open ideas.

### Stage A — known dead-ends from this iteration (don't redo blindly)

Three scoring/extraction tweaks were tried and rolled back. Full detail + `file:line` in `tasks/stage_a_tuning.md` § "Failed experiments":

1. **`log(1 + freq)` frequency compression** — collapsed main characters into the tail. `Sung Jinwoo` (freq 15 631) lost dominance, 9 wiki canonicals fell out of top-1515.
2. **Stopword-ratio penalty for capitalized chains** — `stopwords-iso[en]` contains the same `the` / `of` / `in` that the chain assembler uses as connectors. `King of the Dead` got rejected as "≥50% stopwords".
3. **Bracket pattern `[…]` as quoted-span source** — Yen-Press Korean web-novel format wraps whole System sentences in `[…]`, not just skill names. Added 188 noisy long-phrase candidates for 1 wiki strict-hit.

### Deferred (concurrency cluster, full list in `term_extraction_fixes.md`)

1. **`CancelableLangchainRunner` re-entrancy** — `lib/service/ai/langchain_runner.dart:10` holds one `_subscription` at module scope; mining `concurrency` stuck at `1`. Fixing this unlocks a ~3-5× wall-clock win on Stage C.
2. **Real foreground task isolate** — Stage B/C still on main isolate.
3. **Cross-service `PipelineCancellationToken`**.

Non-concurrency leftovers: enum migration for stage / candidate-type strings, `_DiscoveryCancelledException` cleanup, memory peak measurement, Android battery-optimisation request, `tb_glossary_term_variants` review UI, Stage A unit tests.

## Pre-existing notes / things to watch

- The reentrant-`onUpgrade` bug in upstream Anx `case 3:` (logs `Bad state` on fresh install, schema commits OK) is still unfixed and out of scope.
- Plugins `haptic_feedback` and `in_app_purchase_android` still want `compileSdk = 36`; project compiles fine against 35.

---

For prior iterations (1: GlossaryTerm; 2: chapter tables + `ChapterStatus`; 3: first-open chapter parser; 3.5: reference translations + alignment) see `tasks/changelog.md`. Iterations 7-8 + the benchmark are not yet in the changelog (see § “What still needs to happen” item 3).
