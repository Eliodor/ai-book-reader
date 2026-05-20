# Stage A scoring & recall tuning (Solo Leveling benchmark)

Iteration that extended the discovery pipeline (Stage A — iteration 7 from `migration_plan.md`) with cleanup, scoring rebalance and a score-based cutoff. All work is on `master`, **uncommitted**.

## Snapshot — current measured state (Solo Leveling, 102 chapters, 6.5 MB)

| Metric | Value |
|---|---:|
| Pool size (score > 0, no topN cap) | **4 592** |
| strict recall vs Wiki (183 entries, 14 categories) | **73.2%** |
| loose recall vs Wiki | **96.7%** |
| strict recall vs LLM glossary (873 entries) | **57.7%** |
| loose recall vs LLM glossary | **94.0%** |
| Stage A wall time | ~15 s |

For comparison: the *previous* implementation (no cleanup, no scoring tweaks, top-N=1515 cap) produced 1 515 candidates with **61.2% / 87.4% / 35.6% / 78.7%**.

## What's in the pipeline now (working — keep)

1. **`text_artifacts.dart` → `cleanTermArtifacts`** — strips end-of-sentence punctuation (`.,!?;:…`) and collapses runs of >2 identical chars to 2. Kills `Ah!`, `Ahhh!!`, `Ahhhh……` → `Ahh`. Applied in `_emitSpan` and `_ingestQuotedSpans`. **−9% raw candidates** for free.
2. **Stopword-guard in `_ingestQuotedSpans`** — for multi-word quoted spans, reject if `firstWord ∈ stopwords` or `lastWord ∈ stopwords` or `≥50%` words are stopwords. Removes dialogue fragments like `"Are you Hunter Jinwoo Sung?"`. Universal across all 57 stopwords-iso languages.
3. **Type boost in `CValueScorer`** — `proper_name × 1.4`, `title × 1.3`, `organization × 1.3`, `technique × 1.2`. Uses the existing `_classify` signal so cost is zero.
4. **Softer substring penalty for frequent proper-names** — when `candidateType == 'proper_name'` and `frequencyTotal ≥ 10`, multiplier is `0.6` instead of the default `~0.3`. Rescued `Adam White` (freq 19), `Sung Jinwoo`, `Metus`.
5. **Dispersion for all candidates** — `DispersionScorer` no longer takes a `topK` cap. Evenly-spread low-frequency terms get the same up-to-2× Gries DP boost as the head.
6. **First-chapter recency bonus** — `×1.2` for candidates first introduced in the first ⅓ of chapters and recurring `freq ≥ 5` times. Isolate computes `earlyChapterIds` from `chapter.orderIndex < ceil(chapters/3)`.
7. **`minScore` floor** — `DiscoveryInput.minScore = 0.0` (default). After sort by score-desc, the first candidate with `score ≤ minScore` truncates the list. Removes ~2 000 zero-score tail entries. **`topN` still hard-caps as safety net.**
8. **Tokenizer apostrophe-s strip** — `Token.normalizedText` strips trailing `['’ʼ]s` (English possessive). `Kamish's` → `kamish`. Affects internal dedup; the original `text` keeps the apostrophe for display.

## Failed experiments — DO NOT re-try without rethinking

### E. `log(1 + freq)` frequency compression — CATASTROPHIC
- **Tried**: replace `cValue = logLen × freq` with `cValue = logLen × log(1 + freq)`.
- **Effect**: strict vs Wiki at top-1515 collapsed `64.5% → 48.1%`. Nine wiki canonicals fell out of top-1515 including the protagonist `Sung Jinwoo`.
- **Why**: `log(15632) ≈ 9.66` for the protagonist vs `log(20) ≈ 3.0` for a side character — ratio compressed from 80× to 3×. Combined with the new multiplicative boosts (A+B+C+D, all `×1.2–×1.4`), side characters with proper_name type boost easily overtook main characters.
- **Lesson**: linear `frequencyTotal` is the right anchor for narrative text. The fact that main characters are also the most frequent words isn't a bug to compress away — it's the signal.

### F. Stopword-ratio penalty for **capitalized chains** — BROKE WIKI TERMS
- **Tried**: in `_emitSpan`, reject chains of `>2` words where `≥50%` of tokens are in `stopwords[language]`.
- **Effect**: strict vs Wiki at top-1515 dropped `64.5% → 60.1%`. Pool barely shrunk.
- **Why**: `stopwords-iso[en]` includes `the`, `of`, `in`, `and` — and those are exactly the **connectors** the chain assembler uses (and the `universalArticles` allow-list also lets in). Wiki canonicals `King of the Dead`, `Lord of the Flies`, `Queen of Insects` have 2/4 or 2/3 words in stopwords → rejected by F.
- **Lesson**: stopwords-iso ≠ "non-content words inside a chain". Don't double-count connectors as a noise signal. The existing boundary check (first/last token can't be stopword) is enough for chains. F worked fine in `_ingestQuotedSpans` because quoted spans aren't built from connector-chains.

### B. Bracket pattern `[…]` in `_ingestQuotedSpans` — TOO NOISY
- **Tried**: extend the quoted-span regex to also capture `\[([^\[\]]{3,40})\]`, expecting `[Stealth]`, `[Detection]`-style skill names.
- **Effect**: pool +188 candidates, but **only 1** newly-strict wiki canonical (`ice bears`). Most additions were long System-message sentences: `Shadow Extraction has failed`, `Buff Detoxing has been activated`, `Iron is using Skill Epic Taunt`, `3 2 1 Detoxing is complete`.
- **Why**: in Yen-Press-translated Korean web-novels, `[…]` wraps entire System-message *sentences*, not just the skill name. The right abstraction is "tokenize inside the brackets and run the capitalized-chain detector", not "treat the bracket content as a single phrase".
- **Lesson**: see open idea (1) below for the right shape of this feature.

### Apostrophe-strip in benchmark `normalizeForMatch` — would be cheating
- The tokenizer strip (#8 in keep-list) does help internal dedup but **doesn't move bench numbers** because `term_matcher.dart` matches `normalizeForMatch(sourceText)`, and `sourceText` keeps the apostrophe. To get `Kamish's Wrath` (wiki canonical) to strict-match a pool candidate, we'd need the candidate's *source* form to be `Kamish's Wrath` — which it isn't in Solo Leveling because the book only ever embeds it inside `[ITEM: KAMISH'S WRATH]`. **Don't "fix" this by stripping in `normalizeForMatch`** — that would inflate recall numbers without actually solving the underlying extraction problem.

## Open ideas — try next

### 1. Run `_emitSpan` on bracket-content (the right way to do "B")
- Treat each `[…]` match as a mini-sentence. Tokenize the inside, run the capitalized-chain pipeline against it.
- Expected wins: `[ITEM: KAMISH'S WRATH]` → `KAMISH'S WRATH` becomes its own 2-word candidate with `normalized_source = "kamish wrath"` (thanks to existing tokenizer strip). Same for `[Demon Monarch's Necklace]`, `[Cartenon Temple's Key]`, `[Ruler's Hand]`.
- Risk: low — bracket content is short and capitalization-rules apply.
- Files: factor a `_ingestTokenizedSpan(List<Token>, …)` helper out of the chapter loop in `_emitSpan`; call it from both `ingestChapter` and a new `_ingestBracketChainCandidates`.

### 2. Lowercase channel for high-frequency plurals/categories
- 100% miss rate currently on `goblins`, `dragons`, `archers`, `assassins`, `nagas`, `ice elves`, `hunters`, `demons` — Stage A's capitalization-only rule excludes them by design.
- Heuristic: a lowercase token with `freq ≥ N` across `chapters ≥ K`, AND that appears at least once Title-Cased somewhere reliable (chapter title, post-period sentence-start with mid-sentence backing per the existing `_trustToken` logic) → promote as `proper_name` candidate.
- Risk: tuning N/K is sensitive. Wrong cutoff lets in `boss`, `enemy`, `hero`. Needs a precision audit, not just recall.
- Files: new method in `CandidateGenerator`, runs after `_prepass`.

### 3. Wire `minScore` through `TermDiscoveryService`
- **Live gap**: `TermDiscoveryService.discoverIfNeeded` only forwards `topN`, not `minScore`. The default `DiscoveryInput.minScore = 0.0` is therefore only active in the CLI tool. The on-device pipeline still ships everything ≤ topN regardless of score.
- Fix: add `defaultMinScore = 0.0` to `term_discovery_constants.dart`, plumb a parameter through `discoverIfNeeded`, set the field on `DiscoveryInput`.
- Also: consider raising `adaptiveDiscoveryTopN` to ~10 000+ so the score floor becomes the primary cutoff and topN is purely a safety net.

### 4. Move bench-side morphology normalisation into `MorphologyClusterer`
- `benchmarks/term_extraction/lib/term_normalizer.dart` does case+hyphen+plural folding (`A rank` / `A-Rank` / `A-rank` → `A-Rank`). On the LLM 8-volume output it cut 911 → 873.
- Same folding inside the app's `MorphologyClusterer` would pick display forms that match wiki canonicals more reliably (e.g. `A-Rank` vs `A Rank`). Expected: +1-2 п.п. strict recall.
- Cluster-rep selection in `morphology_clusterer.dart` currently uses `frequencyTotal` desc — extend to prefer the variant with the most uppercase + dash, tie-break on non-plural.

### 5. Persist `firstChapterOrderIndex` on `RawCandidate`
- Currently the recency bonus relies on `earlyChapterIds` (set of IDs). Computed in `term_discovery_isolate.dart` from the input snapshot. Works but couples the scorer to that set.
- Cleaner: store `firstChapterOrderIndex` directly on `RawCandidate`; `DispersionScorer` reads `cand.firstChapterOrderIndex < totalChapters/3`. No external set needed.

### 6. Strip apostrophe-s from `sourceText` too — debatable
- Today: tokenizer strips `'s` from `normalizedText` only. `sourceText` (display) keeps the original.
- If we also strip from the join-built `sourceText` in `_emitSpan`, the bench would actually start counting `Kamish's Wrath` matches via `Kamish Wrath` source. UI displays the stripped form (`Kamish Wrath`), which is debatable for English glossaries but probably fine in Ukrainian / Russian glossaries (no possessive `'s` at all).
- Decide together with idea (1) — once bracket-chain extraction lands, this may stop mattering.

## Files touched in this iteration (uncommitted, on `master`)

**New**:
- `lib/service/pipeline/discovery/text_artifacts.dart`

**Modified — pipeline core**:
- `lib/service/pipeline/discovery/candidate_generator.dart`
- `lib/service/pipeline/discovery/cvalue_scorer.dart`
- `lib/service/pipeline/discovery/substring_penalizer.dart`
- `lib/service/pipeline/discovery/dispersion_scorer.dart`
- `lib/service/pipeline/discovery/term_discovery_isolate.dart`
- `lib/service/pipeline/discovery/tokenizer.dart`

**Benchmark instrument** (`benchmarks/term_extraction/`):
- `lib/term_normalizer.dart` — new, shared case+hyphen+plural folding
- `tool/normalize_terms.dart` — new, applies normalizer to LLM glossary
- `tool/normalize_stage_a.dart` — new, applies normalizer to Stage A output
- `tool/merge_volume_terms.dart` — new, merges 8 per-volume LLM extractions
- `bin/run_benchmark.dart` — added `--terms-json=<path>` and `--ground-truth=<path>` flags

**Benchmark data** (`benchmarks/term_extraction/data/solo-leveling/`):
- `extracted_terms.json` — 911 raw LLM-extracted terms (8 parallel agents over 8 volumes)
- `extracted_terms_normalized.json` — 873 deduped after normalizer
- `extracted_terms_groups.json` — canonical → variants map
- `cache/terms/volume_NN_terms.json` × 8 — per-volume LLM output
- `discovery_output.json` — current Stage A output (4 592 candidates)
- `stage_a_normalized.json` — same applied through bench normalizer (no-op currently — Stage A already dedups internally)
- `stage_a_groups.json`

## How to verify (Windows desktop, no app rebuild needed)

```bash
# 1. Regenerate Stage A output
dart run tool/run_discovery_benchmark.dart \
  "benchmarks/term_extraction/data/solo-leveling/book/" \
  "benchmarks/term_extraction/data/solo-leveling/discovery_output.json" \
  --top-n=99999

# 2. Bench against Wiki (categorised JSON)
cd benchmarks/term_extraction
dart run bin/run_benchmark.dart \
  --discovery-output=data/solo-leveling/discovery_output.json \
  --precision-sample=0
# Expected: 4 592 candidates, TOTAL  183  73.2%  96.7%

# 3. Bench against LLM glossary (plain string array)
dart run bin/run_benchmark.dart \
  --discovery-output=data/solo-leveling/discovery_output.json \
  --ground-truth=data/solo-leveling/extracted_terms_normalized.json \
  --precision-sample=0
# Expected: TOTAL  873  57.7%  94.0%
```

## On-device verification — still TODO

The same pipeline code runs in the app's isolate via `TermDiscoveryService`. The CLI tool exercises everything except the DB persistence and the foreground-task host. Three things to confirm before this iteration can be considered done:

1. **`flutter run -d <device>` once, hot-restart after pipeline changes, trigger term extraction on a real book.** Verify `tb_term_candidates` row count matches expected pool size for that book.
2. **`minScore` is currently isolate-internal only.** See open idea (3) — wire it through the service before the on-device pipeline reflects the cutoff. Right now the on-device pool will still be whatever `adaptiveDiscoveryTopN` produces.
3. **Multi-language smoke**: pick a Ukrainian or Russian EPUB, confirm tokenizer + stopwords path lights up correctly, scoring boosts don't misfire.
