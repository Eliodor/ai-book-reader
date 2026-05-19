# Term Extraction Benchmark

Standalone CLI tooling for measuring the quality of Stage A (Discovery) and
Stage A+B (Discovery + LLM filter) against a third-party glossary, without
touching the app's UI, database, or any device.

**Not part of the Flutter app build.** Pure Dart CLI in an isolated
`pubspec.yaml`. Nothing here ships to end users.

## Why this exists

Every glossary we own was produced by our own pipeline, so it can't validate
itself. This harness builds an independent benchmark from public fandom wikis
(plus optionally from LLM-extraction of the book itself) and then measures:

- **Recall** — what fraction of ground-truth terms our pipeline found.
- **Precision** — what fraction of our pipeline's candidates are real terms
  (optional, requires manual labelling).

The first target is **Solo Leveling** (`solo-leveling.fandom.com`).

## Three-step flow

```
                        ┌─────────────────────────┐
                        │  fan wiki (Fandom API)  │
                        └────────────┬────────────┘
                                     │  step 1
                                     ▼
                ┌──────────────────────────────────────┐
                │  data/<wiki>/ground_truth_raw.json   │
                │  (all wiki terms + Epithets)         │
                └────────────┬─────────────────────────┘
                             │  step 2 (needs EPUB on disk)
                             ▼
                ┌──────────────────────────────────────┐
                │  data/<wiki>/ground_truth.json       │
                │  (only terms actually in the book)   │
                └────────────┬─────────────────────────┘
                             │
                             ▼
   ┌────────────────────────────────┐   step 3a — run Stage A pipeline
   │ tool/run_discovery_benchmark   │   on the EPUB directly via Isolate.spawn
   │ (in repo root, NOT here)       │   — no UI, no DB.
   └────────────┬───────────────────┘
                │
                ▼
   data/<wiki>/discovery_output.json (1500 candidates + stats)
                │
                ▼
   ┌────────────────────────────────┐
   │  bin/run_benchmark.dart        │   step 3b — recall table + precision
   │  --discovery-output=...        │   sample CSV
   └────────────────────────────────┘
```

## Step-by-step

### Step 1 — fetch glossary from wiki

```bash
cd benchmarks/term_extraction
dart pub get
dart run bin/fetch_glossary.dart solo-leveling
```

Walks the default category list and follows subcategories recursively
(`Characters` → `S-Rank Hunters` → individual character pages). Pages are
de-duplicated by title across categories. Non-content namespaces
(`Category:`, `Template:`, etc.) are filtered. For each page, the `Epithet`
field in the infobox is parsed as **additional terms** in the `titles`
sub-list — these are stand-alone things the algorithm should find on their
own (e.g. "Shadow Monarch", "Knight of Death"), not aliases of the canonical
name.

All HTTP responses are cached under `data/<wiki>/cache/`. Re-runs are
instant; delete the cache to force a fresh fetch. Polite throttling is 300ms
between requests.

Output: `data/<wiki>/ground_truth_raw.json`.

### Step 2 — filter ground truth by book text

```bash
# EPUB or TXT — put your book here first.
dart run bin/filter_by_text.dart data/solo-leveling/book/SoloLeveling.epub
```

Strips HTML from every `*.xhtml`/`*.html` inside the EPUB, NFC-normalises
+ lowercases the result, then keeps only terms that appear in the text at
least once (whole-word match via fast `String.indexOf` + manual boundary
check — `RegExp.allMatches` is ~50× slower on a 4 MB corpus and not worth
the unicode-property niceties).

The wiki includes lore from sequels, manhwa, anime, side stories — this
step drops anything not present in *your specific copy*. Output:
`data/<wiki>/ground_truth.json`.

**Books are user-supplied (copyright).** `data/<wiki>/book/` is gitignored.

### Step 3a — run Stage A discovery on the EPUB (no app, no DB)

Run from the **repo root**, not from this folder:

```bash
cd D:/Projects/AIBookReader
dart run tool/run_discovery_benchmark.dart \
  benchmarks/term_extraction/data/solo-leveling/book/SoloLeveling.epub \
  benchmarks/term_extraction/data/solo-leveling/discovery_output.json
```

Why in the root: this script reuses the in-repo Stage A pipeline
(`lib/service/pipeline/discovery/term_discovery_isolate.dart` and its
siblings) directly. All of those files are pure Dart; the only Flutter
piece (`stopwords_loader.dart`'s `rootBundle`) is bypassed by reading the
stopwords asset from `assets/data/stopwords-iso.json` on disk.

So no Flutter SDK, no UI, no foreground task, no `Isolate.spawn` from an
app entry point. Just `Isolate.spawn(discoveryIsolateEntry, ...)` and the
result lands as JSON.

Solo Leveling reference run on Windows desktop: **~13.5 s** for 272
chapters / 4.4 M characters / 1500 final candidates (Yen Press equivalent
sizing).

### Step 3b — compute recall

```bash
cd benchmarks/term_extraction
dart run bin/run_benchmark.dart \
  --discovery-output=data/solo-leveling/discovery_output.json \
  --wiki=solo-leveling
```

Prints a per-category recall table — both **strict** (exact NFC+lower
match) and **loose** (whole-word substring with `|candidate| ≥ 4` and a
stopword filter, which is what catches "Jinwoo" covering "Sung Jinwoo").

Also writes `data/<wiki>/precision_sample.csv` — 200 randomly-picked
candidates. **Manual labelling is optional**; if you want a precision
number, open the CSV in Excel, fill `is_term` with `1/0/?` (yes/no/unsure),
save, then:

```bash
dart run bin/run_benchmark.dart aggregate-precision \
  data/solo-leveling/precision_sample.csv
```

## Alternate path — on-device DB (when Stage A+B has run inside the app)

If you ever want to compare the Stage A+B (post-LLM-filter) numbers against
Stage A alone, you'll need the app's `app_database.db`:

```bash
# Pull from Android (DO NOT use `adb shell cat` — CRLF translation
# corrupts the binary on Windows). See CLAUDE.md rule 20.
adb exec-out run-as io.github.eliodor.aibookreader \
  cat ./databases/app_database.db > /tmp/app_database.db

# On Windows desktop the DB lives under your %APPDATA% somewhere similar.

dart run bin/run_benchmark.dart \
  --db=/tmp/app_database.db --book-id=42 \
  --wiki=solo-leveling
```

In this mode the recall table has two columns: Stage A (all rows) and
Stage A+B (excludes `status='rejected'`).

## Layout

```
benchmarks/term_extraction/
├── bin/
│   ├── fetch_glossary.dart      step 1
│   ├── filter_by_text.dart      step 2
│   └── run_benchmark.dart       step 3b (recall + precision sample)
├── lib/
│   ├── fandom_api.dart          cached HTTP client + recursive subcategories
│   ├── wikitext_parser.dart     infobox field extractor
│   ├── book_text_loader.dart    EPUB/TXT → plain text
│   ├── term_matcher.dart        fast indexOf + unicode word boundary
│   └── benchmark_metrics.dart   strict + loose match, recall by category
├── tool/
│   └── smoke_test.dart          synth SQLite + metrics sanity check
├── data/<wiki>/
│   ├── cache/                   raw API responses (gitignored)
│   ├── ground_truth_raw.json    output of step 1
│   ├── ground_truth.json        output of step 2
│   ├── discovery_output.json    output of step 3a
│   ├── precision_sample.csv     output of step 3b (optional)
│   └── book/                    user-supplied EPUB (gitignored)
├── pubspec.yaml
├── analysis_options.yaml
└── README.md
```

The Stage A driver (`tool/run_discovery_benchmark.dart`) lives in the repo
root next to the app's `lib/`, because it depends on
`package:ai_book_reader/...`. The standalone benchmark package does not
depend on `ai_book_reader` (and can't — the Flutter SDK constraint would
make `dart pub get` fail in pure-Dart context).

## Known gotchas

### Translation mismatch

Different English releases of the same novel use different terminology.
For Solo Leveling specifically:

| Webnovel.com ("Only I Level Up", 2018) | Yen Press (2021)        |
| -------------------------------------- | ----------------------- |
| Sovereigns                             | Monarchs                |
| Osborne                                | Ashborn                 |
| "Rise up"                              | "Arise"                 |
| Seong Jin-Woo                          | Sung Jin-Woo            |

The fandom wiki uses the Yen Press canonical form. If your EPUB is the
Webnovel version, you'll see artificially low recall on the Monarchs /
Rulers / titles categories because those terms are physically absent from
the text. Either use the Yen Press edition, build a manual alias mapping,
or use the LLM-extraction path described below.

### Same canonical can live in multiple categories

`Sung Jinwoo` appears in `Characters` (via Korean Hunters subcat) **and**
`Hunters`. The benchmark counts him twice in `terms` totals — which
slightly inflates per-category counts but does not bias the recall ratio.
If this matters for a future analysis we can dedupe by canonical in
`computeRecallByCategory`.

### Strict vs loose

`strict` is the honest number — it asks for an exact NFC+lower match.
`loose` allows a candidate that is a whole-word substring of the canonical
(or vice versa), length ≥ 4, not a stopword. Loose models the real use case
("Jinwoo" is the same person as "Sung Jinwoo" for glossary purposes);
strict shows you how much benefit the loose rule provides.

## Adding more wikis

```bash
dart run bin/fetch_glossary.dart <subdomain>
# e.g. dart run bin/fetch_glossary.dart mother-of-learning
```

Pass an explicit category list when the wiki uses different naming:
```bash
dart run bin/fetch_glossary.dart <subdomain> Characters Spells Locations
```
