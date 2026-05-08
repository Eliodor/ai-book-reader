---
name: reference_novel_translator
description: Read-only Python reference repo at D:\Projects\NovelTranslator — has the original LLM pipeline, prompts, and DB schema being ported to Dart.
type: reference
---

`D:\Projects\NovelTranslator\` — Python project that AI Book Reader is porting **from**.

Read-only. Nothing is copied verbatim. Use it to:
- Read prompt text in `modules/services/prompts/` (translation.py, candidate_mining.py, candidate_filtering.py, mining.py, structure.py, genre_presets.py).
- Read DB schema in `core/database/models.py` (SourceChapter, TargetChapter, GlossaryTerm, NgramAnalysis, TermCandidate, TermCandidateOccurrence, ProjectConfig).
- Read pipeline step logic in `steps/` (parser_step, translator_step, candidate_discovery_step, candidate_guided_miner_step, fb2_export_step). **Note:** the original brief mentions cleaner_step/miner_step/ngram_analyzer_step — these have been deleted in favor of the candidate-guided workflow. The brief is slightly out of date.
- Read agent context in `tasks/active_context.md` and `tasks/tasks_plan.md` for the latest production workflow shape.

Two production workflows in the Python repo: (1) Direct Import→Translate→Export, (2) Reference-assisted glossary via paired EN/RU import → CandidateDiscovery → CandidateGuidedMiner → Translate → Export.

**Why care:** prompt text is well-tuned and should be ported close to the original. Schema decisions (composite key on `term_source`, JSON-string `meta` columns, `ChapterStatus` enum lifecycle) should inform the Dart port.

When you need a one-off Python investigation ("does this regex actually match?"), do it in the Python repo, summarize the result in words/comments, but never add a Python script to the Dart repo.
