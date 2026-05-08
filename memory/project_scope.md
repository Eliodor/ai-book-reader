---
name: project_scope
description: AI Book Reader is a Flutter rebrand of Anx Reader; goal is to port the NovelTranslator Python pipeline (parse, glossary mining, translate, FB2 export) into pure on-device Dart.
type: project
---

AI Book Reader = Anx Reader fork (MIT, package renamed to `ai_book_reader`, app id `io.github.eliodor.aibookreader`) + a multi-month port of the NovelTranslator Python pipeline into Dart.

Pipeline parts to port (over many sessions, not all at once):
- SQLite schema for source/target chapters, glossary terms, term candidates
- Translation prompts (translation, candidate mining, candidate filtering, genre presets)
- Active steps: ParserStep, TranslatorStep, CandidateDiscoveryStep, CandidateGuidedMinerStep, Fb2ExportStep
- Two workflows: (1) direct Import→Translate→Export, (2) reference-assisted glossary via paired EN/RU import.

Already done before this session: full rebrand (1567 import rewrites in 298 files, all platform manifests, IAP id, method-channel id, removed `com/example` template). Debug APK builds and launches on the test device. Outstanding rebrand TODOs (URLs to anx.anxcye.com, Apple Team ID, Inno GUID, app icons) live in `docs/RENAME_TODOS.md` — not blocking.

**Why:** User wants a single Flutter app for both reading translated novels and translating new ones, replacing the Python desktop pipeline.

**How to apply:** When suggesting features or refactors, evaluate them against the migration plan in `tasks/migration_plan.md`. Don't recommend features outside scope of "translate + read on phone." Don't suggest backend services. Defer rebrand-cleanup items unless explicitly asked.
