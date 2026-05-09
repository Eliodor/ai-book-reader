# Active Context

## Current Focus

**Iteration 2 — chapter tables + `ChapterStatus` enum — DONE (uncommitted).**

Iteration 1 (`GlossaryTerm` slice) was committed prior to this session — working tree was clean at start. Iteration 2 layers two more pipeline tables on top of v8.

## What landed in this session (in working tree, uncommitted)

- `lib/models/chapter_status.dart` — `enum ChapterStatus { newly, parsed, translated, analyzed }`. Each variant carries a `dbValue` matching the Python enum string. `cleaned` / `mined` from the Python original are deliberately omitted: the upstream steps that produced them (`CleanerStep`, `MinerStep`) have been deleted, and we have no legacy data to migrate.
- `lib/models/source_chapter.dart` — model for `tb_source_chapters`. Final-field constructor + `copyWith` + `toMap` + `fromDb`, identical pattern to `GlossaryTerm`.
- `lib/models/target_chapter.dart` — model for `tb_target_chapters`. Same pattern; carries `sourceChapterId` (FK) plus its own `orderIndex` because translation may temporarily lag the source.
- `lib/dao/source_chapter_dao.dart` — `BaseDao` subclass: `save` (upsert keyed on `(book_id, order_index)`), `selectById`, `selectByBookIdAndOrder`, `selectByBookId`, `selectByStatus`, `countByBookId`, `updateStatus`, `deleteById`, `deleteByBookId`.
- `lib/dao/target_chapter_dao.dart` — same shape; upsert keyed on `source_chapter_id`.
- `lib/dao/database.dart` — `currentDbVersion` bumped 8 → 9. New `case 8:` migration creates both tables with `UNIQUE` constraints, an FK from target → source (`ON DELETE CASCADE`), and `(book_id)` + `(book_id, status)` indexes on each.
- `lib/providers/chapters.dart` — `@riverpod class SourceChapters extends _$SourceChapters` and `@riverpod class TargetChapters extends _$TargetChapters`, both parameterized on `bookId`. `chapters.g.dart` regenerated under `dart run build_runner build`.

## Verification done in this session

- `dart run build_runner build --delete-conflicting-outputs` — succeeded after ~73s with 1330 outputs.
- `flutter analyze` on the seven touched files — clean, no issues.
- `flutter build apk --debug` — built `app-debug.apk` successfully (~10 min).
- `adb install -r app-debug.apk` to Samsung SM S721B (`R5CY604D5BV`) — Success.
- App launched via `adb shell monkey ... LAUNCHER` and remained running.
- Pulled `app_database.db` via `adb exec-out run-as ... cat ...` and inspected with Python `sqlite3`:
  - `user_version = 9`
  - `tb_source_chapters` and `tb_target_chapters` present with expected `CREATE TABLE` SQL.
  - Both `UNIQUE` constraints present (`tb_source_chapters(book_id, order_index)`, `tb_target_chapters(book_id, source_chapter_id)`).
  - Four chapter-related indexes present: `idx_source_chapter_book_id`, `idx_source_chapter_status`, `idx_target_chapter_book_id`, `idx_target_chapter_status`.

## Known issue (pre-existing, NOT iteration 2)

On a fresh install path (case 0 → newVersion), the **upstream Anx** `case 3:` migration logs an unhandled exception:

```
Bad state: This can happen if an inner synchronized block is spawned outside the block it was started from.
  at DBHelper.onUpgradeDatabase.<anonymous closure> (lib/dao/database.dart:448)
  at BaseDao.queryList (...)
  at DBHelper.database (...)
```

Root cause: `case 3:` calls `bookDao.selectBooks().then(...)` while `onCreate` is still holding the sqflite database lock. Reentrant open → exception. Pre-existing code from the Anx fork, present in `master` since well before this session. Effect on iteration 2: zero — the schema still commits (verified `user_version = 9` and chapter tables are queryable), and the app continues launching into onboarding. Document for future work; do not fix as part of this iteration.

## Up next (when user opens the next session)

- User decides whether/how to commit this slice.
- **Iteration 3** — translation prompts + single-chapter manual translate. Port translation prompt text from `D:\Projects\NovelTranslator\modules\services\prompts\translation.py` into `lib/service/ai/prompt_generate.dart`, build `lib/service/pipeline/translator_service.dart` for one chapter, bind to a developer-only debug button. See `tasks/migration_plan.md` § "Iteration order".

## Notes / things to watch

- The reentrant-`onUpgrade` bug above is worth a separate, scoped fix later — probably by deferring the cover-reset side-effect from `case 3:` into a post-init step.
- Plugins `haptic_feedback` and `in_app_purchase_android` keep warning that they want `compileSdk = 36`; project compiles fine against 35 today.
