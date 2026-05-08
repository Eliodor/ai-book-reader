# Active Context

## Current Focus

**Iteration 1 — discovery + GlossaryTerm slice — DONE (uncommitted).**

The working tree carries the slice but nothing is staged or committed; the user controls all git writes.

## What landed in this session (in working tree, uncommitted)

- `CLAUDE.md` — entry-point doc (running, architecture, dev rules, branch policy, test device, follow-ups). *(Note: project `.gitignore` ignores `CLAUDE.md` — user must `git add -f CLAUDE.md` if they want to track it.)*
- `tasks/migration_plan.md` — multi-month migration plan and iteration order.
- `tasks/active_context.md`, `tasks/changelog.md` — agent working-memory files.
- `docs/migration-map.md` — Python-source → Dart-destination table reflecting the actual current state of `D:\Projects\NovelTranslator` (legacy steps `CleanerStep`/`MinerStep`/`NgramAnalyzerStep`/`CandidateFilterStep` are deleted upstream and dropped from the plan).
- `lib/models/glossary_term.dart` — model mirroring Python `GlossaryTerm`. Synthetic `id` PK; `(book_id, term_source)` unique.
- `lib/dao/glossary_term_dao.dart` — DAO following the `BookNoteDao` template; `save` does upsert keyed on `(book_id, term_source)`.
- `lib/dao/database.dart` — schema bumped from v7 to v8; new `case 7:` migration creates `tb_glossary_terms` + `idx_glossary_book_id`.
- `lib/providers/glossary.dart` — `@riverpod class Glossary extends _$Glossary { Future<List<GlossaryTerm>> build(int bookId); upsert; remove; clear; refresh; }`. Generated `glossary.g.dart` exists locally (gitignored).
- `memory/` — agent memory store (gitignored if pattern matches; not in standard `.gitignore`).

## Verification done in this session

- `flutter pub get` — OK.
- `flutter gen-l10n` — already configured via `l10n.yaml`, no work to do.
- `dart run build_runner build --delete-conflicting-outputs` — OK; `glossary.g.dart` generated.
- `flutter analyze` on the four touched files — clean (no issues).
- `flutter run -d R5CY604D5BV` — APK built (~125s), installed (~5s), Dart VM service attached, app launched on the Samsung phone. User confirmed it works.

## Up next (when user opens the next session)

- User decides whether/how to commit the slice. Agent must NOT run any write-side git ops (`feedback_no_git_writes.md`).
- **Iteration 2** — chapter tables (`tb_source_chapters`, `tb_target_chapters`) + `ChapterStatus` enum + DAOs. See `tasks/migration_plan.md` for the rough iteration order.

## Notes / things to watch

- `.gitignore` includes `CLAUDE.md` and `*.g.dart` — when staging, user may want `git add -f CLAUDE.md` to track the agent guide.
- `lib/main.dart:203` still has `title: 'Anx Reader'` (cosmetic rebrand leftover, listed in `docs/RENAME_TODOS.md`).
- Plugins `haptic_feedback` and `in_app_purchase_android` warn that they want `compileSdk = 36`; project compiles fine against 35 today, no action needed yet.
