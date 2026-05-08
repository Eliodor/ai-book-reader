# Migration Plan — NovelTranslator (Python) → AI Book Reader (Dart)

This is the multi-month migration plan that drives every pipeline-related change in this repo. Each session works on a slice of it, ships an end-to-end vertical, and updates `tasks/active_context.md` + `tasks/changelog.md`.

> **Source of truth for the *current* state of the Python repo:** `D:\Projects\NovelTranslator\AGENTS.md` and `D:\Projects\NovelTranslator\tasks\active_context.md`. The migration map below reflects the actual state of the Python repo as of session start (2026-05-08). Some legacy steps mentioned in older briefs (`CleanerStep`, `MinerStep`, `NgramAnalyzerStep`, `CandidateFilterStep`) have been **deleted upstream** — they are not part of this plan.

## Goal and principles

Port the working novel-translation pipeline from `D:\Projects\NovelTranslator\` to pure Dart in this repo. Final product: a single Flutter app on the user's phone that both **reads** translated novels (existing Anx Reader feature) and **translates** new ones (new feature, ported from Python). 2-4 weeks of effort across multiple sessions.

Principles:

- **Not a literal copy.** Improve API shape, lean into Dart idioms (sealed classes, freezed, riverpod), reshape for mobile UX. The prompt *text* is the most worth-preserving thing — the rest can be redesigned.
- **Mobile-first.** Each decision is judged by "how does this behave on a phone?" Heavy ops in Isolate; progress, cancellation, and resume are mandatory.
- **Reuse what Anx already has.** Don't rewrite LLM clients (`langchain_dart`), FB2/EPUB parsing, sqflite plumbing, or the WebView reader. Plug pipeline outputs into them.

## Migration map

The **finalized version** of this table is in `docs/migration-map.md` (it is updated as each slice ships). Below is the raw plan as agreed at session start.

| Python source | Dart destination | Strategy |
|---|---|---|
| `core/database/repository.py` | new DAO classes in `lib/dao/` | Read schema and method signatures. Re-implement DAO-by-DAO using Anx's `BaseDao` (`lib/dao/base_dao.dart`) and the `book_note.dart` template. Do not port `Repository` as a single god-class. |
| `core/database/models.py` (`SourceChapter`, `TargetChapter`, `GlossaryTerm`, `NgramAnalysis`, `TermCandidate`, `TermCandidateOccurrence`, `ProjectConfig`) | new files in `lib/models/` + new tables added to `lib/dao/database.dart` (bumped DB version) | Re-model in Dart: `final` fields + `copyWith` + `fromDb`/`toMap`. `freezed` only where value-equality / JSON pays off. Tables can be merged or split if it improves the mobile UX (e.g. `ProjectConfig` may become per-book metadata in `tb_books`). |
| `modules/llm_client/clients.py` + `factory.py` + LLM profile config | **not ported** | Anx already has `langchain_dart` (OpenAI, Anthropic, Gemini) wired through `lib/service/ai/`. Reuse it. Profile-style task/model overrides are achievable through Dart helpers around `langchain_runner.dart`, but that is a later design pass. |
| `core/context/execution_context.py` | Riverpod providers + a new `lib/service/pipeline/` namespace | Don't port the `ExecutionContext` god object. Riverpod handles DI. Pipeline steps in Dart receive `Ref` and read DAOs / `langchain_runner` from providers. |
| `modules/services/prompts/translation.py` | extend `lib/service/ai/prompt_generate.dart` (`generatePromptTranslate`, `generatePromptFullTextTranslate` already exist as starting points) | Port prompt text close to original. Add system+user message split and JSON-mode output where the original used it. |
| `modules/services/prompts/candidate_mining.py`, `candidate_filtering.py`, `mining.py`, `structure.py`, `genre_presets.py` | `lib/service/ai/prompt_generate.dart` (or split into `prompts/` subfolder if it gets big) | Same as above. Genre presets become a Dart `enum` or `sealed class`; phrase fragments stay as constants. |
| `steps/base_step.py` | `lib/service/pipeline/base_step.dart` (new) | Define a `PipelineStep` abstraction in Dart. Could be an abstract class with `Future<void> execute(Ref ref)` or a `sealed class` with one variant per step. Decide at first port. |
| `steps/parser_step.py` (FB2/EPUB import) | reuse `lib/service/book.dart` (Anx's importer) — extend it | Don't port the parser. Anx already imports FB2/EPUB. Extend the importer to populate the new `tb_source_chapters` / `tb_target_chapters` tables when the book is opened in "translation mode." |
| `steps/translator_step.py` | new `lib/service/pipeline/translator_service.dart` | Heaviest port. Includes glossary RAG-lite, rolling source/target context, parallel chunk translation, transient-error retry, glossary audit. On phone: parallelism is throttled hard, retries log to UI, and DB writes are serialized. |
| `steps/candidate_discovery_step.py` | `lib/service/pipeline/candidate_discovery_service.dart` | Regex + N-gram extraction over source chapters that have a target translation. Pure CPU work — must run in an Isolate. |
| `steps/candidate_guided_miner_step.py` | `lib/service/pipeline/guided_miner_service.dart` | LLM-assisted mining of candidates into glossary terms. Uses `candidate_mining.py` prompts. |
| `steps/fb2_export_step.py` | `lib/service/export/fb2_export_service.dart` | Export translated book as FB2. On mobile: share-sheet / "Save to..." rather than file dialog. |
| `modules/ngram_optimizer/optimizer.py` | `lib/service/pipeline/ngram_service.dart` | Pure-Dart N-gram ranking. Bound the corpus size on phones; it doesn't need to process 4000 chapters at once. |
| `modules/services/glossary_matcher.py` | `lib/service/pipeline/glossary_matcher.dart` | Token-index lookup for fast English-source glossary hit detection during translation. Pure Dart, easy port. |
| `project_manager.py` (project registry DB) | merged into Anx's `tb_books` / new per-book metadata | On mobile, "project" and "book" collapse: one book = one translation project. Decide concrete shape during translator port. |
| `interactive.py` (Python CLI) | new UI screens in `lib/page/` | Not a port — a redesign. Mobile UX: per-book "translation" tab, run-step buttons, foreground-service progress, glossary editor accessed via long-press in the reader. |
| `utils/bench_translation_modes.py` | maybe `test/` or a dev-only screen | Defer. Not user-facing. |

## Mobile-first design choices

- Heavy ops always in `Isolate` (via `compute()` or `Isolate.spawn`). UI thread never blocks.
- Android — long jobs inside a **foreground service** with a system notification showing progress. iOS — app must stay open (Apple background limits); UI says so honestly.
- Cancel + resume on every step. Closing the app, an incoming call, or screen sleep must not lose progress. Persist via SQLite, never in-memory.
- Push-style notification when a batch finishes.
- Pull-to-refresh, progress bars, animations — natural mobile patterns.
- Glossary edited in-place: long-press a term in the reader → edit translation / note.
- Genre presets ("LitRPG", "wuxia", "soft sci-fi") as buttons, not CLI flags.
- Translation can start from any chapter — mobile reading is non-linear.
- Battery-aware: pipeline asks before continuing if battery is low.

## What we are NOT porting

- `OLD/` — archived legacy code in the Python repo. Skip entirely.
- `utils/` PowerShell/Windows-specific desktop scripts.
- `main.py` / CLI argument flow — mobile is launched by tap, not flags.
- `requirements.txt`, `.env` parsing — Dart has its own config story (`flutter_dotenv` or `--dart-define`); pick one when LLM config is ported.

## Risks & anti-patterns

- **Temptation to "just drop a Python script" into the fork.** Violates non-negotiable constraint #1. No `tools/translator/`, `scripts/python/`, `helpers/`. If you need quick Python research, do it in `D:\Projects\NovelTranslator\` as a throwaway and write the result down in words / Dart comments.
- **Heavy-step performance on phone.** Mining a whole book may be infeasible on-device. Solution is *not* to revive a Python backend — it's to rethink the step (incremental per-chapter, sample-cap, defer to charging+wifi).
- **Upstream drift.** Anx Reader releases every 2-3 weeks. Sync `develop` from upstream once every 1-2 months and merge into `master`. Also watch for license changes (history: MIT → GPLv3 → MIT). If upstream switches to a copyleft license again, freeze on the last MIT commit and stop pulling.

## Iteration order (rough)

1. **Iteration 1 — discovery + GlossaryTerm slice.** *(this session)* DAO + model + Riverpod provider for glossary terms only. Verify the existing Anx schema accepts our new tables. No UI.
2. **Iteration 2 — chapter tables + status enum.** Add `tb_source_chapters`, `tb_target_chapters`, `ChapterStatus` enum. DAO + provider. No UI.
3. **Iteration 3 — translation prompts + single-chapter manual translate.** Port translation prompts; build `translator_service.dart` for one chapter; bind to a developer-only debug button.
4. **Iteration 4 — parser hook into source chapters.** Extend Anx's importer to populate `tb_source_chapters` when the user opts in.
5. **Iteration 5 — pipeline UI shell.** Per-book "translate" tab; run-step buttons; basic progress.
6. **Iteration 6 — Isolate + foreground service.** Run translation off the UI thread; Android notification.
7. **Iteration 7 — TermCandidate tables + CandidateDiscoveryService.**
8. **Iteration 8 — Candidate-guided mining.**
9. **Iteration 9 — FB2 export + share sheet.**
10. **Iteration 10 — glossary editor (long-press in reader).**
11. **Iteration 11 — translateText handler in `epub_player.dart` calls our pipeline.**

This list is intentionally rough; each iteration starts with its own discovery pass and may resequence.

## What is explicitly NOT in iteration 1

- Porting any prompts.
- Implementing any pipeline service (cleaner / translator / miner / etc).
- Any UI for the pipeline.
- Plugging the new glossary into the foliate `translateText` handler.
- Page-curl animation (eBoox-style) — separate visual layer via `riveo_page_curl` shader; deferred.
- Audit + simplification of Anx UI for end users.
- Subscription / monetization / app store publishing.
- `docs/RENAME_TODOS.md` items (URLs, icons, Apple Team ID, Inno GUID).

Each of those is its own future iteration with its own discovery + verification.
