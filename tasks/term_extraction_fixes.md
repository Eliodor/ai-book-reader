# Term Extraction Pipeline — Follow-up Fixes

> **Status (2026-05-17, end of day):** original 9 fixes + multi-source review correctness fixes + the second-round non-concurrency bug fixes landed. **DB bumped to v12** (new `tb_mining_progress` table). `flutter analyze` clean on all 22 touched files. Still uncommitted, still awaiting on-device verification. See **”Implementation log (2026-05-15)”** for the original 9, **”Follow-ups discovered during multi-source review (2026-05-17)”** for the review-driven ones (incl. the new ones from end of day). Concurrency-related items (parallel mining, runner re-entrancy, foreground task isolate) are explicitly deferred to a separate session per user instruction.

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

Greedy set-cover over chapters (`mining_chapter_selector.dart`) to cover 80% of the score-weighted accepted+uncertain candidates. For each selected chapter: send (full source chapter, full target chapter, terms list) to LLM. Prompt requires base-form / lemma translations (critical for uk/pl/de morphology — without it «Дракон» / «Дракона» / «Дракону» end up as three distinct glossary entries).

Each `(source, target)` pair runs through `mining_postfilter.dart`, then **upserts a vote into `tb_glossary_term_variants`** keyed by `(book_id, term_source, term_target_normalized)` where `term_target_normalized = NFC(lower(target)).replaceAll(/\s+/, ' ')`. Counts accumulate across chapters. After all chapters processed: `aggregateWinners` picks `MAX(count)` per `term_source` and upserts the winner into `tb_glossary_terms`. Corresponding candidates flip to `status='promoted'`.

**No LLM arbiter** for conflicts — pure frequency voting (per user requirement). Alternative variants stay in `tb_glossary_term_variants` for future audit UI.

## Implementation log (2026-05-15)

All 9 fixes from the “Issues to fix” section landed in source. Each fix below lists its status, the file(s) where the change went, and any decision worth remembering for review.

### Status summary

| Fix | Severity | Status | Touched file(s) |
|---|---|---|---|
| 1 — connector-chain walker | HIGH | ✅ done | `lib/service/pipeline/discovery/candidate_generator.dart` |
| 2 — emit inner sub-spans | HIGH | ✅ done | `lib/service/pipeline/discovery/candidate_generator.dart` |
| 3 — pre-C-value frequency filter | HIGH | ✅ done | `lib/service/pipeline/discovery/term_discovery_isolate.dart` |
| 4 — real cancellation via `Isolate.spawn` | HIGH | ✅ done | `term_discovery_isolate.dart`, `term_discovery_service.dart`, `cvalue_scorer.dart`, `lib/providers/term_extraction.dart`, `lib/widgets/book_detail/term_extraction_card.dart` |
| 5 — sentence-initial guard relaxed | MED | ✅ done | `candidate_generator.dart` |
| 6 — reorder cluster ↔ dispersion | MED | ✅ done | `term_discovery_isolate.dart` |
| 7 — ISO → English language names | MED | ✅ done | `lib/service/ai/locale_names.dart` (new), `lib/service/pipeline/mining/term_mining_service.dart` |
| 8 — propagate `min(firstChapterId)` | LOW | ✅ done | `lib/service/pipeline/discovery/morphology_clusterer.dart` |
| 9 — exclude connectors from `wordCount` | LOW | ✅ done | `candidate_generator.dart` |

`flutter analyze` against all 9 touched files: **0 issues** (run on 2026-05-15, 228 s on Windows). Not committed.

### Decisions worth remembering

- **Connector chain length** capped at `_maxConnectorChain = 3` (private const in `candidate_generator.dart`). Tuned to match the doc’s “up to 3 consecutive connectors” instruction; covers “Master of the” / “Lord of the Rings” class of names without absorbing whole clauses.
- **Sentence-initial trust threshold** = `3` (`_sentenceInitialTrustThreshold`). Per the doc’s tuning guess. Could be raised for very short-sentence books later.
- **Cancellation contract.** The isolate uses a sentinel string (`discoveryCancelSignal = 'discovery_cancel'`) over a private `SendPort`, not a custom class. Simpler than a sealed message hierarchy and survives the cross-isolate boundary without surprises.
- **C-value cancel check cadence** = every 1000 outer-loop iterations (`_cancelCheckInterval` in `cvalue_scorer.dart`). Picked so a typical 1500-candidate book yields ≤ 2 yields and a 50k pre-prefilter book still observes cancel within a few hundred ms.
- **`CValueScorer.score` made async.** Returns `Future<Map<String, RawCandidate>>` and takes an optional `isCancelled` callback. On cancel observed, returns early with the current partial state (the worker then sends a `discoveryCancelledResult` and throws away the partial). The signature change is internal to the discovery pipeline; nothing outside the isolate calls it directly.
- **Pre-filter cap** = `_maxCandidatesAfterPrefilter = 20000` (in `term_discovery_isolate.dart`). Engaged only when the pool is still oversize after the hapax pass; sorts by raw frequency and keeps top-N. New stat field `prefilteredCount` flows through `DiscoveryStats` and is logged.
- **`DiscoveryStats` field set changed.** Added `prefilterMs` and `prefilteredCount`; removed nothing. Anything that read these fields outside `term_discovery_service.dart`’s log line would break, but the grep audit showed no other readers.
- **Pipeline order is now Tokenize → Generate → Prefilter → CValue → Cluster → BuildChapterCounts+DP → Substring → Sort & cap.** Cluster runs *before* DP. Clustering seeds with C-value × YAKE only (no DP), per the doc’s explicit caveat. Empirical verification deferred to the on-device run.
- **Cluster winner `firstChapterId`** is now `min` across all members (not just the winner’s own value), guarded with a `1 << 30` sentinel so a null doesn’t silently win.
- **`localeToEnglishName` covers 70+ codes** — the Snowball list plus the rest of `stopwords-iso.json` mapped through standard ISO 639-1 names. Unknown codes pass through unchanged. Applied only at the mining call site (`term_mining_service._runMiningOnce`), not at the translator prompt or Stage B filter prompt (those weren’t in scope).
- **New UI state `TermExtractionCancelled`** terminates the flow with a small “Скасовано користувачем” summary in the card; the Start/Reset buttons re-enable because it’s not a *running* state. No new strings for the localization file — Ukrainian-only label inlined, matching the rest of the card.
- **Provider `cancel()`** now also calls `termDiscoveryService.cancel()` (was Filter+Mining only). The service forwards the signal to the active worker; if the worker hasn’t reported its cancel port yet, the request is buffered (`_cancelRequested = true`) and sent as soon as the `DiscoveryIsolateReady` handshake message arrives.

### Out-of-scope follow-ups discovered while working

(All items in the original “Out of scope” section still apply; no new ones discovered.)

### What remains before this iteration can be archived

1. **On-device verification** on Windows desktop and Samsung phone against the acceptance criteria at the bottom of this file. Discovery has never run end-to-end with the new code. The first realistic run still needs a book with translated `tb_target_chapters` rows (Iteration 4 single-chapter translate is not landed yet — manual SQL pre-seed required, same as before the fixes).
2. **Commit cadence decision** (carried over from `active_context.md` — covers iterations 1-8 plus these fixes).
3. After verification + commit: changelog entry, and either delete this file or move it to `tasks/archive/`.

---

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

**Symptom:** "Дракон" / "Дракона" / "Дракону" (Ukrainian morphological variants) each get their own DP value, then get clustered, then the cluster's `score = average(member.score)` — which dilutes the dispersion boost.

**Fix:** swap so clustering runs first. Caveat: clustering today seeds with `Score₂ desc`. After the swap, seeding uses just C-value × YAKE features (no DP yet). That is probably fine because casing + dif-sentence are already strong-enough seeds; verify empirically.

After clustering, build `chapterCounts` from the aggregated cluster's chapter set + summed within-chapter occurrences, then run DP on the survivors.

#### Fix 7 — LLM prompts see ISO codes, not language names

**Files:** `lib/service/pipeline/mining/term_mining_service.dart`, possibly new `lib/service/ai/locale_names.dart`.

**Symptom:** The mining prompt template includes `{{from_locale}}` / `{{to_locale}}`, but the controller passes raw ISO codes (`"ru"`, `"uk"`, `"en"`). Strong LLMs handle this, weaker ones get confused.

**Fix:** add a `String localeToEnglishName(String code)` helper mapping `en→English`, `uk→Ukrainian`, `de→German`, `pl→Polish`, … (start with the same 17 codes the Snowball list covers, plus the rest of `stopwords-iso` keys mapped via the standard ISO 639-1 table). Use it on both `fromLocale` and `toLocale` before they hit the prompt.

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

## Follow-ups discovered during multi-source review (2026-05-17)

Surfaced by a 4-way review (manual + `simplify` 3 sub-agents + `code-review-excellence` + cross-comparison with the prior session). All fixes from the table above (1-9) plus the items marked ✅ below landed; the rest are deferred with the reasons recorded so the next session doesn't re-derive them.

### Applied in this iteration

- ✅ **Gries DP correctness** — added `Map<int,int> chapterFrequencies` on `RawCandidate` (populated exactly in `_emitSpan`, `_ingestQuotedSpans`, `ingestNonLatinNgrams`; merged across morphological variants in `MorphologyClusterer`). `DispersionScorer.score` now reads it directly; `buildChapterCounts` / `ChapterCount` deleted. **Reason this matters:** with `maxOccurrencesPerCandidate = 2`, the previous fallback in `buildChapterCounts` fired for every frequency > 2 candidate and silently degraded DP into a binary "in many chapters or not" signal — defeating the point of Fix 6 (cluster-before-DP).
- ✅ **Filter/Mining `Cancelled` outcomes** — added `FilterCancelled` and `MiningCancelled` sealed variants; provider routes them to `TermExtractionCancelled`. Removed `_CancelledException` from filter (it was only ever used as a marker).
- ✅ **`superCandidateKeys: Set<String>`** — replaced the `Set<int>` of `hashCode` values with normalized-source keys. Stops birthday-paradox collisions (≈ 4% at 20k candidates) inflating C-value's `avgNested` divisor.
- ✅ **`lib/service/ai/ai_retry.dart`** — extracted the 3-attempt exponential backoff loop shared between filter `_callLlm` and mining `_callWithRetry`. Exposes `isTransientAiError(Object)` so the same predicate can also replace the substring-sniff in `lib/service/ai/index.dart:_mapError:307-327` when we get to it.
- ✅ **N+1 in filter snippets** — `selectFirstByCandidateIds(List<int>)` in `TermCandidateOccurrenceDao` replaces ~100 round-trips per batch with one INNER-JOIN-on-MIN query.
- ✅ **Mining `bulkUpsertVariants` in a single transaction** — `_mineChapter` now collects all `(source, target)` pairs into `List<VariantUpsert>` and ships them in one `db.transaction(batch.commit(noResult:true))`. Old `upsertVariant` kept for compatibility.
- ✅ **Worker pool plumbing for Stage C** — `mineIfNeeded` takes `concurrency` (default `1`, see runner caveat below).
- ✅ **Mining resumability (DB v12)** — new table `tb_mining_progress(book_id, source_chapter_id, mined_at)` + `MiningProgressDao`. `mineIfNeeded` loads `selectMinedChapterIds` at the start and `markMined` after each successful chapter (or empty-terms chapter), the worker pool skips already-mined ids, and `TermExtraction.reset()` clears the table for the book. Stops Stage C from double-counting variant votes when a run is restarted mid-flight.
- ✅ **`extractJson` double-fence handling** — peels up to two fence layers (some models wrap `` ```json …``` `` inside another `` ``` …``` ``).
- ✅ **`_batchSize` resets per filter run** — adapted (halved) size no longer leaks to the next book.
- ✅ **`mining_postfilter.dart` regexes hoisted** — 4 inline regexes moved to `static final`, saving the per-call compile.
- ✅ **C-value inner-loop string allocation** — `' $normalizedSource '` is pre-computed once per candidate into a side map; the substring scan now reads from it instead of allocating a fresh wrapper string per probe.
- ✅ **Trivials** — dead stopword check (candidate_generator.dart:220), `bestAllCount.toString();` no-op (mining_chapter_selector.dart:88), useless `byNormalized` copy in C-value.
- ✅ **Russian → Ukrainian in project surfaces** — UI strings in `term_extraction_card.dart` and notifications in `term_extraction.dart`, mining-prompt morphology example in `ai_prompts.dart`, acceptance criteria + comments in this file. Russian remains supported as a source language via `connectorsByLanguage['ru']`, Snowball backend, and the `localeToEnglishName` mapping — only demonstration / UI surfaces switched.

### Blocking the parallel-mining win — fix this next

- **`CancelableLangchainRunner` is not re-entrant.** `lib/service/ai/langchain_runner.dart:10` holds **one** `_subscription` at module scope. Two concurrent streams overwrite each other; `cancelActiveAiRequest()` (`lib/service/ai/index.dart:67`) can only cancel the latest. Until this is fixed, `term_mining_service.dart:mineIfNeeded(concurrency: …)` must stay at `1`. Shape of the fix: return `(Stream<String> stream, Cancelable cancel)` from `stream()` / `streamAgent()` and update the 1-2 callers in `lib/service/ai/index.dart`. After that, raise mining default to `3` for a ~3-5× wall-clock win on multi-chapter mining.

### Deferred — architectural / sized

- **Cross-service `CancellationToken`.** Each of `TermDiscoveryService`, `TermFilterService`, `TermMiningService` has its own ad-hoc cancel flag. A single token passed from the provider through all three stages would remove the three near-identical `cancel()` / `resetCancellation()` blocks and unify the semantics. Sketch:
  ```dart
  class PipelineCancellationToken { bool get isCancelled; void cancel(); }
  ```
  Discovery additionally needs to forward the cancel to its `SendPort`; Mining still needs `cancelActiveAiRequest()`. Half-day refactor; doable once the runner is re-entrant.
- **Memory peak in `_emitGroup` before the prefilter.** [candidate_generator.dart:151](lib/service/pipeline/discovery/candidate_generator.dart:151) — emits `O(C²)` sub-spans per multi-word group; prefilter at `term_discovery_isolate.dart:_prefilterCandidates` runs *after* the whole generation. On a fantasy / cultivation novel with many proper-noun chains, the candidate map can balloon temporarily. **Action:** measure peak heap on a low-end Android (4 GB) before deciding to inline a frequency check in the emitter.

### Deferred — stylistic / polish

- **Stage strings → enum.** `'load-chapters'`, `'detect-language'`, `'discover'`, `'persist'` (Discovery); `'mine'`, `'aggregate'`, `'select-chapters'`, `'build-coverage'`, `'load-candidates'` (Mining). UI's `default: state.stage` fall-through (term_extraction_card.dart:145, :178) silently swallows typos.
- **Candidate type strings → enum.** [candidate_generator.dart:388-400](lib/service/pipeline/discovery/candidate_generator.dart:388) (`_classify`) returns bare strings (`'proper_name'`, `'phrase'`, `'organization'`, `'technique'`, `'title'`). `CandidateType` enum already exists in `lib/models/candidate_type.dart` and is used by the DAO mapper at [term_discovery_service.dart:286](lib/service/pipeline/discovery/term_discovery_service.dart:286). Return the enum directly from the generator.
- **`_DiscoveryCancelledException` for control flow.** [term_discovery_isolate.dart:151](lib/service/pipeline/discovery/term_discovery_isolate.dart:151) — exception-for-flow is an anti-pattern but pragmatic without a Dart `CancellationToken`. Leave as-is until the cross-service token lands.
- **Mixed typed/untyped isolate messages.** `DiscoveryIsolateReady/Result/Error` are typed classes alongside string sentinels `discoveryCancelSignal` / `discoveryCancelledResult`. Pick one. Trivial.

## Acceptance criteria

Pipeline can be considered "trustworthy" after fixes 1-7 land:
- A 500k-word EPUB book on Windows desktop runs Stage A in ≤ 60 s (target 20-40 s, allow buffer for first-run).
- Synthetic test: "Master of the Crimson Hall stood tall" appears once in a sample chapter → resulting `tb_term_candidates` contains the full 5-word string AND both "Master" and "Crimson Hall" as separate rows.
- A Ukrainian-source book: «Дракон», «Дракона», «Дракону», «Драконом» all collapse into one cluster (via the char-trigram Jaccard fallback — Snowball doesn't ship a Ukrainian backend), winner = «Дракон», `chapter_count` aggregated across all four forms.
- Cancel button stops Stage A within 3 s instead of waiting for full completion.
- Stage B sends ≤ 35 LLM calls for a book with ~1500 candidates (verify via log).
- Stage C `tb_glossary_terms` rows have **dictionary-form** translations (no «-а», «-у», «-ом» case suffixes for Ukrainian / Polish / other morphology-rich source languages).

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
