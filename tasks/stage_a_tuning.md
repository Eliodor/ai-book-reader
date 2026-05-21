# Stage A scoring & recall tuning (Solo Leveling benchmark)

Iteration that extended the discovery pipeline (Stage A — iteration 7 from `migration_plan.md`) with cleanup, scoring rebalance and a score-based cutoff. All work is on `master`, **uncommitted**.

## Snapshot — current measured state (Solo Leveling, 102 chapters, 6.5 MB)

| Metric | Value |
|---|---:|
| Pool size (score > 0, no topN cap) | **2 250** |
| strict recall vs Wiki (183 entries, 14 categories) | **68.9%** |
| loose recall vs Wiki | **95.6%** |
| strict recall vs LLM glossary (873 entries) | **46.6%** |
| loose recall vs LLM glossary | **88.3%** |
| Stage A wall time | ~11 s |
| C-value time (was the dominant cost) | 309 ms (was 2 962 ms) |

For comparison:
- *Pre-tuning* (no cleanup, no scoring tweaks, top-N=1515 cap): 1 515 candidates, **61.2 / 87.4 / 35.6 / 78.7**.
- *Post-tuning without heuristic junk filter*: 4 592 candidates, **73.8 / 96.7 / 57.8 / 94.0**.

The heuristic junk filter trades **−4.9 p.p. strict recall vs Wiki** for **−51% pool size** and **−90% C-value runtime**. At the user's projected scale (2 600-chapter book, ~30 k raw candidates), this is the difference between ~75 LLM calls in Stage B and ~150.

### Primary metric — `loose recall vs Wiki`

Iterated decision: **the Wiki-curated ground truth is the canonical signal of Stage A quality.** Reasons:

1. **Wiki is human-curated.** Anything in `ground_truth.json` is a real glossary term by definition; nothing in there is a duplicate, a publisher name, a quoted sentence, or a wrong canonical.
2. **LLM glossary is noisy** — the 8 parallel agents each extracted independently, and the deduplicated 873-term list contains:
   - ~80 duplicates (e.g. `Chris Reed` / `Christopher Reed` / `Christopher "Chris" Reed`),
   - ~15 publisher/edition mentions (`Yen Press`, `Solo Leveling II`, `D&C MEDIA`, `BBN News`),
   - Korean-order name variants the Yen Press translation never uses (`Yoo Jinho` vs book's `Jinho Yoo`),
   - ~250 fleeting one-chapter mentions a curator wouldn't have included.

   When we apply Stage A's own structural filters (`cleanTermArtifacts` + heuristic junk + apostrophe-strip) to the LLM glossary, 590 of 873 terms (67.6%) survive. The other 283 fall into the same junk buckets as Stage A noise. Saved as `data/solo-leveling/extracted_terms_filtered.json` for any future reference — we are **not** going to keep benchmarking against the LLM glossary; the filtered version exists only as a debug artefact.

3. **Loose vs Wiki = 95.6%** for the current pool is independently confirmed by **loose vs filtered LLM = 94.6%** — they agree to within 1 p.p. The 6 p.p. drop seen against the raw LLM glossary is therefore mostly LLM noise, not a real regression.

## What's in the pipeline now (working — keep)

1. **`text_artifacts.dart` → `cleanTermArtifacts`** — strips end-of-sentence punctuation (`.,!?;:…`) and collapses runs of >2 identical chars to 2. Kills `Ah!`, `Ahhh!!`, `Ahhhh……` → `Ahh`. Applied in `_emitSpan` and `_ingestQuotedSpans`. **−9% raw candidates** for free.
2. **Stopword-guard in `_ingestQuotedSpans`** — for multi-word quoted spans, reject if `firstWord ∈ stopwords` or `lastWord ∈ stopwords` or `≥50%` words are stopwords. Removes dialogue fragments like `"Are you Hunter Jinwoo Sung?"`. Universal across all 57 stopwords-iso languages.
3. **Type boost in `CValueScorer`** — `proper_name × 1.4`, `title × 1.3`, `organization × 1.3`, `technique × 1.2`. Uses the existing `_classify` signal so cost is zero.
4. **Softer substring penalty for frequent proper-names** — when `candidateType == 'proper_name'` and `frequencyTotal ≥ 10`, multiplier is `0.6` instead of the default `~0.3`. Rescued `Adam White` (freq 19), `Sung Jinwoo`, `Metus`.
5. **Dispersion for all candidates** — `DispersionScorer` no longer takes a `topK` cap. Evenly-spread low-frequency terms get the same up-to-2× Gries DP boost as the head.
6. **First-chapter recency bonus** — `×1.2` for candidates first introduced in the first ⅓ of chapters and recurring `freq ≥ 5` times. Isolate computes `earlyChapterIds` from `chapter.orderIndex < ceil(chapters/3)`.
7. **`minScore` floor** — `DiscoveryInput.minScore = 0.0` (default). After sort by score-desc, the first candidate with `score ≤ minScore` truncates the list. Removes ~2 000 zero-score tail entries. Is now the **primary cutoff** — `topN` was raised to act as a safety net.
   - `defaultDiscoveryTopN`: 1 500 → **3 000** (anchor for the adaptive formula)
   - `maxAdaptiveTopN`: 5 000 → **30 000** (ceiling)
   - On Solo Leveling (102 ch): adaptive topN = 3 000, pool with score>0 = 2 250 → topN is not active, score floor decides.
   - On Sword God (2 600 ch): adaptive topN = 15 297, projected pool ~12 000 → still score-driven.
   - Only books with extremely rich casts (10 000+ chapters that *somehow* yield >30 000 positive-score candidates after the heuristic junk filter) will see topN truncation.
8. **Tokenizer apostrophe-s strip** — `Token.normalizedText` strips trailing `['’ʼ]s` (English possessive). `Kamish's` → `kamish`. Affects internal dedup; the original `text` keeps the apostrophe for display.
9. **Inverse-U length factor in `CValueScorer`** — replaces classic Frantzi `log2(wordCount)` boost with a table that peaks at `wordCount = 2` and decays away. Concrete factors: `1: 1.2, 2: 1.5, 3: 1.2, 4: 0.7, 5: 0.4, 6+: 0.2`. Glossary terms in narrative text are 1-3 words (almost never 5+), unlike scientific corpora where C-value was designed and longer = more specific. Effect on Solo Leveling: `Penalty Zone` +970 ranks, `Dungeon Jackals` +773, `Adam White` +206; cost was 1 wiki epithet (`King of Monstrous Humanoids`) drifting out of the top-1515 slice while staying in the full pool.

10. **Heuristic junk filter in Etap 1.3** (`_heuristicJunkFilter` in `term_discovery_isolate.dart`) — runs *before* C-value. Drops two structural noise classes:
    - **Fleeting one-chapter mentions**: `chapter_count == 1` AND `frequency_total <= heuristicJunkSingleChapterMaxFreq` (default `2`). Targets ALL-CAPS abbreviations (`Atm`, `Sos`, `Hp Hp`, `Gps`, `Ptsd`), onomatopoeia (`Skraah Skree`, `Rrrummble`), generic common nouns that landed sentence-initial just once (`Friendship`, `Boss`), and one-off System lines (`Item Ballpoint Pen`, `Sliced Pork Belly`).
    - **Long phrases**: total word count (with connectors) `>= heuristicJunkLongPhraseWordCount` (default `5`). Targets dialogue and System sentences that slipped through the chain assembler.

    Trade-off: removes ~2 300 candidates on Solo Leveling (51% of pool), loses 9 wiki canonicals (`dungeon jackals`, `essence stones`, `penalty zone`, `s-rank` directly + 5 indirectly through cluster representative reshuffling). C-value runtime drops from 2 962 ms to 309 ms because C-value is O(K²) over the pool size — this is the single biggest performance lever in Stage A. Constants in `term_discovery_constants.dart` are tunable per future calibration round.

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

### 3. Wire `minScore` override through `TermDiscoveryService` (partially done)
- **Live state**: `DiscoveryInput.minScore = 0.0` is the constructor default, and `TermDiscoveryService.discoverIfNeeded` uses that default by not specifying the field. So on-device the score>0 cut already runs.
- Remaining gap: there's no way to pass a non-default `minScore` from the service caller. If a future iteration wants `minScore = 1.0` (stricter), `discoverIfNeeded` needs a parameter that forwards to `DiscoveryInput`.
- The companion knob — `adaptiveDiscoveryTopN` ceiling — was raised in this iteration from 5 000 → 30 000, so topN is now a safety net rather than the primary cutoff. See keep-list item 7.

### 4. Move bench-side morphology normalisation into `MorphologyClusterer`
- `benchmarks/term_extraction/lib/term_normalizer.dart` does case+hyphen+plural folding (`A rank` / `A-Rank` / `A-rank` → `A-Rank`). On the LLM 8-volume output it cut 911 → 873.
- Same folding inside the app's `MorphologyClusterer` would pick display forms that match wiki canonicals more reliably (e.g. `A-Rank` vs `A Rank`). Expected: +1-2 п.п. strict recall.
- Cluster-rep selection in `morphology_clusterer.dart` currently uses `frequencyTotal` desc — extend to prefer the variant with the most uppercase + dash, tie-break on non-plural.

### 5. Persist `firstChapterOrderIndex` on `RawCandidate`
- Currently the recency bonus relies on `earlyChapterIds` (set of IDs). Computed in `term_discovery_isolate.dart` from the input snapshot. Works but couples the scorer to that set.
- Cleaner: store `firstChapterOrderIndex` directly on `RawCandidate`; `DispersionScorer` reads `cand.firstChapterOrderIndex < totalChapters/3`. No external set needed.

### 7. Tune the length-factor table per source-language
- The current `_lengthFactor` table is calibrated against English (Solo Leveling Yen Press). Other languages may differ:
  - Slavic languages favour 1-word entries (no articles), so peak might shift to `wordCount=1`.
  - German / Dutch (compound nouns) need almost no boost above 1.
  - Chinese / Japanese — tokenisation is different anyway; CJK uses the n-gram channel.
- Idea: ship a `lengthFactorByLanguage` map; default falls back to the English table.
- Don't do this without multi-language benchmark data — premature.

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
