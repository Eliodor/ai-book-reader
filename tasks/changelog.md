# Changelog

Milestones in the AI Book Reader port. Format: `## YYYY-MM-DD — what shipped`.

## 2026-05-08 — Iteration 1: discovery + GlossaryTerm slice (uncommitted)

Onboarding pass on both codebases (Anx-derived AIBookReader and the read-only Python reference at `D:\Projects\NovelTranslator`). Authored `CLAUDE.md`, `tasks/migration_plan.md`, `tasks/active_context.md`, `docs/migration-map.md`.

Implemented the GlossaryTerm vertical slice end-to-end:

- `lib/models/glossary_term.dart` — synthetic-id model; `(book_id, term_source)` unique.
- `lib/dao/glossary_term_dao.dart` — DAO mirroring `BookNoteDao`, with upsert semantics.
- `lib/dao/database.dart` — DB version bumped 7 → 8, new `case 7:` migration creates `tb_glossary_terms` + `idx_glossary_book_id`.
- `lib/providers/glossary.dart` — `@riverpod class Glossary` parameterized on `bookId`.

Verified `flutter pub get` / `dart run build_runner build` clean, `flutter analyze` clean on the touched files, and the app launches on the Samsung SM S721B (id `R5CY604D5BV`). No UI yet — the slice exists only to confirm Anx's architecture cleanly absorbs new pipeline tables.

Working tree left dirty per user instruction; agent does not run write-side git ops.
