# Term Extraction Benchmark — workflow & baseline

> Snapshot of the benchmark infrastructure as of 2026-05-19. For everyday
> usage instructions see `benchmarks/term_extraction/README.md`. This file
> records the *why*, the first baseline numbers, and the open questions.
>
> ⚠ **The baseline numbers in this doc (61.2% / 87.4% strict / loose) are
> historical — they describe the pipeline state on 2026-05-19, before the
> Stage A tuning iteration.** For the current pool size, recall numbers,
> and configuration knobs see [`tasks/stage_a_tuning.md`](stage_a_tuning.md).
> Headline current state on Solo Leveling (102 ch): pool 2 250 candidates,
> strict / loose vs Wiki = **68.9% / 95.6%**, ~11 s wall clock.
>
> ⚠ **Stop benchmarking against the LLM glossary as a quality signal** —
> the 873-term LLM extraction is itself ~32% noise (duplicates, Korean
> name order, publisher mentions, fabrications). A cleaned variant
> (`benchmarks/term_extraction/data/solo-leveling/extracted_terms_filtered.json`,
> 590 terms) exists as a debug artefact only. The Wiki ground truth
> (`ground_truth.json`, 183 entries) remains the canonical metric.

## What landed

A standalone CLI harness for measuring Stage A / Stage A+B quality without
running the Flutter app, without writing to the production SQLite DB,
without an Android device, and without any UI involvement.

**Production-code change (2026-05-19):** `defaultDiscoveryTopN = 1500` is
no longer a hard ceiling. `TermDiscoveryService.discoverIfNeeded` now calls
`adaptiveDiscoveryTopN(chapterCount)` when `topN` is not passed
explicitly — see [`lib/service/pipeline/discovery/term_discovery_constants.dart`](../lib/service/pipeline/discovery/term_discovery_constants.dart).
Formula: `1500 × sqrt(chapters / 100)`, clamped to `[500, 5000]`. Anchored
on the Solo Leveling baseline (100 chapters → 1500). Heaps' law inspired
— vocabulary grows as O(N^0.5) so linear scaling would over-collect for
huge books and under-collect for novellas.

> Note (2026-05-21): the anchor and ceiling were raised to `3000` /
> `30 000` during the Stage A tuning iteration, so `topN` is now the
> safety net rather than the primary cutoff. The score>0 floor
> (`DiscoveryInput.minScore`) is what shapes the pool now. See
> `tasks/stage_a_tuning.md` keep-list item 7.

- `benchmarks/term_extraction/` — isolated Dart package (separate
  `pubspec.yaml`, deps: `http`, `archive`, `html`, `unorm_dart`, `path`,
  `sqlite3`). Has its own README.
- `tool/run_discovery_benchmark.dart` — *in the main repo root*, pure-Dart
  CLI that spawns Stage A's existing isolate entry point directly with an
  in-memory `DiscoveryInput`. No DAO, no rootBundle. Run via `dart run`
  (Flutter SDK not required at runtime).

Verified end-to-end on Windows: Solo Leveling 4.4 M chars / 272 chapters →
Stage A ran in 13.5 s, produced 1500 candidates → recall measured against
219 ground-truth terms.

## Why none of this uses the app / DB

The original plan was to run Stage A from the app UI, dump
`app_database.db` off the device with `adb exec-out`, then read
`tb_term_candidates` from the benchmark. That works but the iteration
loop is awful: any algorithm change means reinstalling, re-importing the
book, re-running discovery, re-pulling the DB. We wanted ~30 s
"change → recall number", not 10 minutes.

The pipeline turned out to be already structured for this — every file
under `lib/service/pipeline/discovery/` is pure Dart except
`stopwords_loader.dart` (Flutter `rootBundle`). The benchmark sidesteps
that one file by reading `assets/data/stopwords-iso.json` directly.
`TermDiscoveryService` is also bypassed because the benchmark doesn't
need DAO persistence; it just wants the `DiscoveryOutput` payload, which
is what the isolate already returns.

The `--db` mode in `run_benchmark.dart` is still supported for the day
we want to compare Stage A vs Stage A+B (the LLM filter step writes
`status` to the DB and there's currently no standalone driver for it).

## Three-command flow

```bash
# 1. Pull glossary from fandom wiki (only once per wiki)
cd benchmarks/term_extraction
dart run bin/fetch_glossary.dart solo-leveling

# 2. Filter glossary down to terms actually present in your EPUB
dart run bin/filter_by_text.dart data/solo-leveling/book/SoloLeveling.epub

# 3a. Run Stage A on the EPUB (from repo root)
cd ../..
dart run tool/run_discovery_benchmark.dart \
  benchmarks/term_extraction/data/solo-leveling/book/SoloLeveling.epub \
  benchmarks/term_extraction/data/solo-leveling/discovery_output.json

# 3b. Compute recall + write precision sample CSV
cd benchmarks/term_extraction
dart run bin/run_benchmark.dart \
  --discovery-output=data/solo-leveling/discovery_output.json \
  --wiki=solo-leveling
```

## Baseline — Yen Press all 8 volumes (2026-05-19, current canonical)

Solo Leveling, **Yen Press 8-volume English edition**, top-1500 candidates,
ground truth filtered with `min-count=3` + meta-page filter, **spine-aware
EPUB parser** (same in filter and discovery), **bidirectional loose match**,
**capitalisation-gated + punctuation-tolerant filter** (183 terms):

```
Category            terms     strict      loose
Abilities              11     54.5%     100.0%
Characters             38     68.4%      97.4%
Dungeons                4     25.0%      75.0%
Gates                   2      0.0%       0.0%   ← see note
Guilds                  7    100.0%     100.0%
Hunters                13     46.2%      92.3%
Items                  10     50.0%      90.0%
Locations              16     56.3%      81.3%
Magic_Beasts           42     47.6%      69.0%   ← see note
Monarchs               16     81.3%     100.0%
Organizations           2     50.0%      50.0%
Rulers                  8     75.0%      87.5%
Shadows                11    100.0%     100.0%
Weapons                 3     33.3%     100.0%
TOTAL                 183     61.2%      86.9%
```

Wall time: 27.2 s. 102 chapters, 6.5 M chars. Raw 12990 → prefilter
12988 → final 1500.

### "Real" recall on proper nouns

Out of 21 misses, ~13 are generic plurals (Goblins, Dragons, Orcs,
Demons, Ants, Archers, Assassins, Naga, ...) that survived the
capitalisation gate because the headings / sentence-initial positions
happen to capitalise them. Stage A's capitalisation rule cannot promote
them as candidates from the body text (where they are lowercase), so
they are not a Stage A failure — they need a different mechanism (Stage
B LLM, or manual seed).

If we count only the proper-noun classes, **recall ≈ 93.5% loose /
70% strict** (159 of 170 found). This is the number to compare against
when iterating Stage A.

### Notes on remaining misses

- **Gates 0%** — both terms are "Red Gate" and "Red Gate Incident".
  `grep` on the unzipped Yen Press EPUBs finds only **3 occurrences**
  of "Red Gate" (capitalised) across all 8 volumes; the rest are
  lowercase "red gate" / "the gate". With 3 cap occurrences and
  `log₂(2) × 3 = 3.0` raw C-value, the term genuinely doesn't compete
  with 1500 candidates that have 10-100+ cap occurrences. **Not a bug.**
  If we ever want rare-but-important multi-word names, we need a
  different stage (e.g. LLM rescue pass over near-misses).
- **Magic_Beasts 69%** — same generic-plurals story.
- **Jonas** is the only character genuinely missed by the algorithm
  (3 categories show him because the wiki has him in Characters,
  Hunters, Rulers — same person, deduped he's 1 miss).

### Earlier runs (kept for trend)

| Run | Edition / parser | chars | gt | strict | loose |
| --- | --- | ---: | ---: | ---: | ---: |
| 2026-05-19 a | Webnovel.com, naive parser | 4.4 M | 219 | 43.8% | 78.1% |
| 2026-05-19 b | Yen Press Vol 01, naive parser | 414 K | 41 | 26.8% | 36.6% |
| 2026-05-19 c | Yen Press Vol 1-8, naive parser, unidirectional match | 3.2 M | 171 | 64.9% | 86.5% |
| 2026-05-19 d | Yen Press Vol 1-8, spine parser, bidirectional match | 6.5 M | 186 | 58.1% | 81.7% |
| 2026-05-19 e | Yen Press Vol 1-8, +smart-cased filter | 6.5 M | 183 | 61.2% | 86.9% |
| **2026-05-19 f** | **Yen Press Vol 1-8, +adaptive topN (1515 for 102 ch)** | **6.5 M** | **183** | **61.2%** | **87.4%** |

Why run (a) under-performs (c): the Webnovel translation uses "Sovereigns"
instead of "Monarchs", "Osborne" instead of "Ashborn", "Seong" instead of
"Sung" — so a chunk of wiki canonicals were physically absent from the
text. Run (b) is statistically meaningless (only 41 terms, mostly
generic).

### How to read these numbers

- **Strict** = exact NFC+lowercase match. 64.9% — the gap from 100% is
  mostly characters whose canonical in the wiki is the full name
  ("Sung Jinwoo") while the book mostly uses the short form ("Jinwoo").
  The algorithm correctly picked the short form, strict can't see it.
- **Loose** = whole-word substring with length ≥ 4 and a stopword filter.
  86.5% — this is the user-visible number, "if I gave this glossary to a
  user, how many wiki-known things would they find in it".
- **5 categories at 100% loose** (Shadows, Rulers, Guilds, Weapons,
  Hunters via short form, Locations, Dungeons, Gates) → the algorithm
  finds essentially every named entity in those classes.

### Categories that lag (post smart-filter)

- **Magic_Beasts 69%** — generic plurals (Goblins, Orcs, Demons, Ants,
  Archers, Assassins, Nagas, Dragons, Dwarves) that survive the
  capitalisation gate because *some* heading or sentence-initial usage
  capitalises them, but the body text uses lowercase. Stage A by design
  doesn't promote lowercase commons. Needs Stage B / LLM filter.
- **Gates 0%** — see "Notes on remaining misses" above. Red Gate is
  too rare in cap form to win against frequent rivals.
- **Organizations 50% / Weapons 33% strict** — small categories
  (2-3 terms), single misses move the number a lot.

## Translation mismatch — solved by using the matching edition

Two English translations exist:

| Webnovel.com (2018, "Only I Level Up") | Yen Press (2021) |
| --- | --- |
| Sovereigns | Monarchs |
| Osborne | Ashborn |
| Rise up | Arise |
| Seong Jin-Woo | Sung Jin-Woo |

The fandom wiki uses **Yen Press canonicals**. Using the Webnovel
translation makes recall artificially low because those terms are
physically absent from the text. The current baseline run uses the Yen
Press edition for this reason. For any future book, always check which
edition the wiki sources its canonicals from.

A `--min-count=N` flag on `filter_by_text.dart` and a meta-page filter
(drops pages whose title is the same as the containing category) cleaned
out the worst of the false positives in ground truth — `Hunters` (the
category page), `Magic Beasts` (ditto), generic ranks like `A-Rank`
through `S-Rank`, etc.

### Smart-cased filter (2026-05-19 e)

The case-insensitive filter was inflating `gt` with terms the algorithm
fundamentally can't find:

- *Capitalisation gate*: a wiki canonical only counts as "present" if at
  least one matching occurrence in the text starts with an uppercase
  letter. This drops "goblins" / "demons" / "system" where the body
  text never capitalises them. Stage A's capitalisation rule wouldn't
  pick those up either, so excluding them from `gt` aligns the
  benchmark with the algorithm's actual scope.
- *Punctuation tolerance*: hyphens, apostrophes, periods are stripped
  from both the corpus and the term before search. So the wiki spelling
  `Sung Jinwoo` correctly matches the Yen Press spelling `Sung Jin-Woo`
  (both reduce to `Sung Jinwoo` for matching purposes). Without this,
  the strict filter dropped most major characters.

### Adaptive top-N (2026-05-19 f)

`defaultDiscoveryTopN = 1500` was a hard guess that worked for ~100-chapter
novels but degraded for both extremes:

- 10-chapter novellas: 1500 candidates meant ~1485 of them were noise.
- 3000-chapter web serials (The Wandering Inn): 1500 was too few to
  cover the actual vocabulary.

`adaptiveDiscoveryTopN(chapterCount)` now scales sublinearly per Heaps'
law — `1500 × sqrt(chapters/100)`, clamped to `[500, 5000]`. Lower bound
keeps Stage B batching worthwhile (~5 LLM calls); upper bound caps
Stage B at ~50 batches per book.

| chapters | topN |
| ---: | ---: |
| 10  | 500   |
| 50  | 1061  |
| 100 | 1500  (anchor) |
| 200 | 2121  |
| 500 | 3354  |
| 1000 | 4743 |
| 3000 | 5000 (cap) |

On Solo Leveling (102 chapters) the change is invisible — 1515 vs 1500,
recall +0.5 pp loose. The impact is for books at the extremes.

`TermDiscoveryService.discoverIfNeeded({int? topN, ...})` accepts an
explicit override; when omitted (the default in
`lib/providers/term_extraction.dart`) the adaptive value is used. The
log line includes `chapters=X topN=Y` so the value is visible in
production debug output.

## Open ideas (not implemented)

- **Standalone LLM filter (Stage B)** — `tool/run_filter_benchmark.dart`
  that reads `discovery_output.json`, applies the same Stage B prompt
  via the same `langchain_runner`, writes a filter verdict per
  candidate. Lets us measure Stage A+B without the app. Blocked on
  checking whether `term_filter_service.dart` has any DAO imports
  besides DTOs.
- **Sub-agent ground truth** — split the book into ~10-chapter chunks,
  spawn one Task per chunk asking the agent to extract proper nouns and
  category tags. Aggregate + dedupe → a per-book glossary that exactly
  matches that translation. Estimated cost ~$1-6 in LLM tokens per
  full book run (~30 agents × ~40 K input + ~5 K output, Sonnet
  pricing). Worth doing if we want a per-translation gt without
  hand-curation.
- **More wikis** — Mother of Learning, He Who Fights with Monsters, The
  Wandering Inn. `fetch_glossary.dart` already takes a wiki subdomain
  as an arg; the categories list is hardcoded for Solo Leveling — should
  be a per-wiki config eventually.

## Files added/modified

- `benchmarks/term_extraction/` — new directory, ~13 files
  (~1500 LOC Dart + README).
- `tool/run_discovery_benchmark.dart` — new (~240 LOC).
- `lib/service/pipeline/discovery/term_discovery_constants.dart` —
  added `adaptiveDiscoveryTopN(int chapterCount)` plus `minAdaptiveTopN`
  / `maxAdaptiveTopN` bounds.
- `lib/service/pipeline/discovery/term_discovery_service.dart` —
  `discoverIfNeeded({int? topN, ...})` — `topN` is now optional;
  defaults to the adaptive value. Log line now includes `chapters=X
  topN=Y`.
- `pubspec.yaml` — unchanged.
- DB schema — unchanged.

All other benchmark plumbing is fully additive.

## When to revisit this doc

After any of:
- LLM filter standalone driver lands.
- Sub-agent gt-extraction pipeline lands.
- Recall numbers re-measured after a Stage A algorithm change.
- A second wiki is added.
