# Term Extraction Pipeline — Follow-up Fixes

> **Status:** active. The three-stage glossary pipeline (Discovery → LLM filter → Pair mining) is fully implemented and `flutter analyze` is clean, but a skeptical code review surfaced 8 issues — three of them HIGH severity — that must be fixed before the pipeline can be trusted on real books.

## Read this first if you are a new session

1. This file — full context + concrete fixes with file:line.
2. `tasks/changelog.md` — the entry "Term extraction pipeline (Discovery + LLM filter + Mining)" describes what landed in the previous session and the list of new files.
3. `C:\Users\Admin\.claude\plans\starry-popping-clock.md` — the original plan (algorithmic intent).
4. `C:\Users\Admin\.claude\plans\starry-popping-clock-agent-ad6be62dd79c96854.md` — algorithm research that justified the choice of C-value / YAKE / single-pass clustering / Gries DP.
5. Source of truth — the actual code (only when the doc above is ambiguous):
   - `lib/service/pipeline/discovery/term_discovery_isolate.dart` — pipeline orchestrator (stages 0-6).
   - `lib/service/pipeline/discovery/candidate_generator.dart` — Stage A Etap 1.
   - `lib/service/pipeline/discovery/cvalue_scorer.dart` — Stage A Etap 2.
   - `lib/service/pipeline/discovery/morphology_clusterer.dart` — Stage A Etap 4.
   - `lib/service/pipeline/filter/term_filter_service.dart` — Stage B.
   - `lib/service/pipeline/mining/term_mining_service.dart` — Stage C.

## Algorithm recap (one-pager)

Three stages, runs per book, gated by the **TermExtractionCard** widget on the Book Detail screen.

### Stage A — Discovery (offline, runs inside `compute()` isolate)

Six internal "etaps":
- **0.** Tokenise (Unicode NFC, sentence splitting). Detect source language by counting how many tokens hit each `stopwords-iso` set (asset).
- **1.** Generate candidates from capitalisation: any token matching `\p{Lu}\p{Ll}+` or `\p{Lu}{2,}`, with a sentence-initial guard. Adjacent capitalised tokens form multi-word groups; language-specific connectors (`of`, `the`, `de`, `von`, `из` …) glue them. Plus quoted spans and an n-gram channel for non-Latin scripts. **No frequency floor at this step today — see Fix 3.**
- **2.** C-value (Frantzi/Ananiadou/Mima 2000) on multi-word candidates: `C(a) = log₂(|a|) · (f(a) − avg(f(super))). ` Truncated YAKE features layered on top: `T_Case` (uppercase ratio) and `T_DifSentence` (sentence dispersion). T_Position and T_Rel intentionally skipped (low ROI per the YAKE authors).
- **3.** Gries DP boost for top-K — `(1 + (1 − DP))`. Rewards terms that recur across chapters.
- **4.** Single-pass clustering of morphological variants (the user's idea). Signature: Snowball stem of `(token_first, token_last)` for Snowball-supported languages (`en, ru, de, fr, es, it, pt, nl, fi, hu, ro, tr, no, sv, da, ar`); char-trigram Jaccard ≥ 0.85 fallback for everything else (notably Ukrainian). Representative inside a cluster = highest raw frequency (the lemma-ish form).
- **5.** Soft substring containment penalty: if `a ⊂ b` and `f(a inside b) / f(a) > 0.8`, multiply `score(a) × 0.5`. Never delete.
- **6.** Sort by score, keep top N=1500, persist to `tb_term_candidates` + `tb_term_candidate_occurrences`. Status = `'candidate'`.

### Stage B — LLM filter (cloud, sequential batches)

Read `status='candidate'` rows. Send them to the LLM in batches of 100 (each batch is `INDEX. "TERM" freq=N ch=M — snippet "..."`). The model replies with a JSON **array of indexes to remove**. The tolerant JSON parser in `lib/service/ai/json_response.dart` strips fences and locates the outer `[...]` with a bracket counter. On parse failure → one retry with a stricter system reminder; on second failure → keep the whole batch (conservative). On truncation → halve batch size and split. Statuses updated: `accepted`, `rejected`, or `uncertain` (the salvage bucket — if >70% of a batch was removed and the removal included a high-score candidate, that one goes to `uncertain` instead of `rejected`).

Cost budget: book of ~1500 candidates ≈ 15 LLM calls; cap at ~35 calls per book in practice.

### Stage C — Pair mining (cloud, per-chapter)

Greedy set-cover over chapters (`mining_chapter_selector.dart`) to cover 80% of the score-weighted accepted+uncertain candidates. For each selected chapter: send (full source chapter, full target chapter, terms list) to LLM. Prompt requires base-form / lemma translations (critical for ru/uk/de morphology — without it «Дракон» / «Дракона» / «Дракону» end up as three distinct glossary entries).

Each `(source, target)` pair runs through `mining_postfilter.dart`, then **upserts a vote into `tb_glossary_term_variants`** keyed by `(book_id, term_source, term_target_normalized)` where `term_target_normalized = NFC(lower(target)).replaceAll(/\s+/, ' ')`. Counts accumulate across chapters. After all chapters processed: `aggregateWinners` picks `MAX(count)` per `term_source` and upserts the winner into `tb_glossary_terms`. Corresponding candidates flip to `status='promoted'`.

**No LLM arbiter** for conflicts — pure frequency voting (per user requirement). Alternative variants stay in `tb_glossary_term_variants` for future audit UI.

## Issues to fix

Concrete file:line is included so a new LLM can land changes without re-discovering them.

### HIGH severity

#### Fix 1 — `_walkGroupEnd` only consumes a single connector

**File:** `lib/service/pipeline/discovery/candidate_generator.dart:107-128`

**Symptom:** "Master **of the** Crimson Hall" is never joined into one candidate. The walker consumes `of` (connector), then expects a capitalised token, but finds `the` (another connector) → break.

**Fix:** scan forward through up to 3 consecutive connectors before requiring the next capitalised + trusted token. Length budget still tracked, but connectors count as soft (don't increment `lengthInWords` past `maxCandidateWordCount` budget by full credit — consider half-credit or 0).

**Test input:** `"Master of the Crimson Hall stood tall."` → expected candidate set includes the full 5-word string.

#### Fix 2 — `_emitGroup` emits only prefixes, never inner substrings

**File:** `lib/service/pipeline/discovery/candidate_generator.dart:130-145`

**Symptom:** Inside the group "Master of Crimson Hall", we emit {Master, Master of, Master of Crimson, Master of Crimson Hall} but **never** {Crimson, Hall, Crimson Hall, of Crimson Hall}. If "Crimson Hall" only ever appears inside the larger phrase, it is lost entirely from the candidate pool — and C-value's soft-penalty cannot rescue it because it never existed as a candidate to begin with.

**Fix:** emit every contiguous sub-span `(from, to)` where `from ∈ [start..end]`, `to ∈ [from..end]`, span length ≥ 1 and ≤ `maxCandidateWordCount`. Skip spans starting or ending with a connector / stopword.

For a length-5 group this is at most C(5,2)+5 = 15 emissions — affordable.

**Test input:** `"Master of Crimson Hall"` (occurs once) → both "Master" and "Crimson Hall" must end up as candidates with `frequencyTotal=1`. Stage 2 substring penalty then sorts out which to keep.

#### Fix 3 — No minimum-frequency pre-filter, C-value explodes O(K²)

**Where:** `lib/service/pipeline/discovery/term_discovery_isolate.dart` — needs a new step between Etap 1 and Etap 2.

**Symptom:** A 500k-word book typically yields 50k-100k candidates after Etap 1, because every capitalised token (including hapax legomena) gets a row. `CValueScorer.score()` then does a substring scan that is `O(K × K_longer)` — that is *billions* of `contains()` calls. The plan promised 20-40 s on a Samsung S24; reality is probably minutes.

**Fix:** prune candidates between Etap 1 and Etap 2 with this rule, applied in order:
- Drop any candidate where `frequencyTotal == 1 AND wordCount == 1` (single-word hapax).
- For `wordCount == 1`, also drop if `frequencyTotal < 2` (after the hapax pass this is a no-op, but keeps the rule explicit).
- Keep all multi-word candidates regardless of frequency (rare unique multi-word strings are usually meaningful).
- Optional cap: if the pool is still above 20 000 after the above, keep only the top 20 000 by `frequencyTotal`.

Add stats to `DiscoveryStats` to surface the pre/post-filter counts.

#### Fix 4 — Real cancellation in Stage A isolate

**Files:** `term_discovery_isolate.dart`, `term_discovery_service.dart`

**Symptom:** `compute()` is atomic. If discovery takes 90 s and the user hits Cancel after 5 s, nothing happens until the isolate naturally finishes.

**Fix:** replace `compute()` with `Isolate.spawn()` + bi-directional `SendPort`. Main isolate sends a `_CancelMsg` over the port; the worker checks an atomic flag (or just reads a message) between every etap (and inside the C-value loop every ~1000 iterations). On cancel detected, return an early `DiscoveryOutput.cancelled()` flavour. Plumb a new `DiscoveryCancelled` outcome through `TermDiscoveryService` and the Riverpod controller.

### MEDIUM severity

#### Fix 5 — Sentence-initial guard too aggressive

**File:** `lib/service/pipeline/discovery/candidate_generator.dart:71-75`

**Symptom:** A protagonist whose name always starts a sentence (very common in novels — "Aragorn drew his sword. Aragorn turned. Aragorn looked.") is dropped because `midSentenceCounts[normalized] == 0`.

**Fix:**
```dart
final mid = _midSentenceCounts[tok.normalizedText] ?? 0;
final initial = _sentenceInitialCounts[tok.normalizedText] ?? 0;
return mid > 0 || initial >= 3;
```

Threshold of 3 is a guess — could be tuned via the book's average sentence length later. The point is: pure sentence-initial recurrence ≥ 3 is strong enough signal.

#### Fix 6 — Cluster before dispersion (re-order Etap 3 ↔ Etap 4)

**File:** `term_discovery_isolate.dart` — reorder pipeline.

**Symptom:** "Дракон" / "Дракона" / "Дракону" each get their own DP value, then get clustered, then the cluster's `score = average(member.score)` — which dilutes the dispersion boost.

**Fix:** swap so clustering runs first. Caveat: clustering today seeds with `Score₂ desc`. After the swap, seeding uses just C-value × YAKE features (no DP yet). That is probably fine because casing + dif-sentence are already strong-enough seeds; verify empirically.

After clustering, build `chapterCounts` from the aggregated cluster's chapter set + summed within-chapter occurrences, then run DP on the survivors.

#### Fix 7 — LLM prompts see ISO codes, not language names

**Files:** `lib/service/pipeline/mining/term_mining_service.dart`, possibly new `lib/service/ai/locale_names.dart`.

**Symptom:** The mining prompt template includes `{{from_locale}}` / `{{to_locale}}`, but the controller passes raw ISO codes (`"ru"`, `"uk"`, `"en"`). Strong LLMs handle this, weaker ones get confused.

**Fix:** add a `String localeToEnglishName(String code)` helper mapping `en→English`, `ru→Russian`, `uk→Ukrainian`, `de→German`, … (start with the same 17 codes the Snowball list covers, plus the rest of `stopwords-iso` keys mapped via the standard ISO 639-1 table). Use it on both `fromLocale` and `toLocale` before they hit the prompt.

### LOW severity

#### Fix 8 — `firstChapterId` after cluster merge

**File:** `lib/service/pipeline/discovery/morphology_clusterer.dart:85-95`

**Symptom:** Cluster winner inherits its own `firstChapterId`. If a less-frequent member appeared earlier in the book (e.g. genitive form in chapter 2, nominative dominates from chapter 5 on), the cluster reports first-chapter = 5, which can skew Stage C's greedy selector.

**Fix:** track `min(firstChapterId)` across cluster members and assign to winner. Pseudocode:
```dart
var minFirst = winner.firstChapterId ?? 1 << 30;
for (var i = 1; i < cluster.members.length; i++) {
  final m = cluster.members[i];
  if (m.firstChapterId != null && m.firstChapterId! < minFirst) {
    minFirst = m.firstChapterId!;
  }
}
winner.firstChapterId = minFirst < (1 << 30) ? minFirst : winner.firstChapterId;
```

#### Fix 9 — `wordCount` includes connectors

**File:** `lib/service/pipeline/discovery/candidate_generator.dart` (in `_emitSpan`)

**Symptom:** "Master of Crimson" gets `wordCount = 3`, inflating `log₂(|a|)` for C-value relative to a clean 2-word "Master Crimson". Cosmetic effect on ranking.

**Fix:** in `_emitSpan`, set `wordCount = parts.where((p) => !connectors.contains(p.toLowerCase())).length`. The display `sourceText` keeps the connectors; only `wordCount` is "content words".

## Out of scope (don't fix here — separate iteration)

- **Real foreground task isolate.** Today `TermExtractionTaskHandler` is a no-op and the pipeline runs in the main isolate. The foreground service holds a wake lock and a notification, which is "good enough" for Android 13 in most cases — but doesn't survive aggressive battery optimisation. A real fix moves Stage B and Stage C into the task isolate and forwards Riverpod state via `FlutterForegroundTask.sendDataToMain`. Big architectural change, do it as its own task once we know we need it.
- **Unit tests for algorithms.** C-value, single-pass cluster, postfilter, JSON parser — all lack tests. Worth a dedicated `tasks/term_extraction_tests.md` slice.
- **Better `looksTruncated` heuristic.** Today it just looks at the last char; ideally we also compare `indexes.length` against an expected distribution.
- **Battery optimisation request.** `FlutterForegroundTask.requestIgnoreBatteryOptimization()` is not called — Android 12+ may kill the service in doze mode for long-running jobs.
- **UI for `tb_glossary_term_variants`.** The voting alternatives are persisted but not surfaced anywhere. A "Review variants" panel is useful but separate work.

## Acceptance criteria

Pipeline can be considered "trustworthy" after fixes 1-7 land:
- A 500k-word EPUB book on Windows desktop runs Stage A in ≤ 60 s (target 20-40 s, allow buffer for first-run).
- Synthetic test: "Master of the Crimson Hall stood tall" appears once in a sample chapter → resulting `tb_term_candidates` contains the full 5-word string AND both "Master" and "Crimson Hall" as separate rows.
- A Russian-source book: «Дракон», «Дракона», «Дракону», «Драконом» all collapse into one cluster, winner = «Дракон», `chapter_count` aggregated across all four forms.
- Cancel button stops Stage A within 3 s instead of waiting for full completion.
- Stage B sends ≤ 35 LLM calls for a book with ~1500 candidates (verify via log).
- Stage C `tb_glossary_terms` rows have **dictionary-form** translations (no «-а», «-у», «-ом» case suffixes for Russian / Ukrainian).

## Algorithm essentials cheat-sheet for a fresh LLM

If you opened this file with zero context:

- The user is porting a Python translation pipeline (`D:\Projects\NovelTranslator`) into pure Dart on-device. **No Python anywhere in this repo. Never add Python.** CLAUDE.md rule 11-12.
- DB migrations are additive only, fall-through `case N:` blocks in `lib/dao/database.dart` (CLAUDE.md rule 2-3). The term-extraction tables are at v11.
- All LLM calls go through `lib/service/ai/` — never instantiate provider clients. CLAUDE.md rule 6.
- Heavy work in an Isolate (CLAUDE.md rule 8). Today Stage A uses `compute()`. Fix 4 will switch to `Isolate.spawn` + `SendPort` for real cancellation.
- Dev verification path: `flutter analyze <touched files>` → `flutter run -d windows` → hot reload. **No `flutter build apk`.** CLAUDE.md rule 18-22.
- Snowball is a Dart pure-port (`snowball_stemmer: ^0.1.0`). Confirmed working in isolate.
- `stopwords-iso` is an asset at `assets/data/stopwords-iso.json` (MIT, 57 languages).
- The plan and research files in `C:\Users\Admin\.claude\plans\` are authoritative for "why" decisions were made.

## When this task is done

- Update `tasks/active_context.md` to point at the next iteration.
- Add a "Term extraction fixes" entry to `tasks/changelog.md` with the date and a short list of what landed.
- Either delete this file or move it to `tasks/archive/` once everything is committed.
