import 'package:ai_book_reader/dao/base_dao.dart';
import 'package:sqflite/sqflite.dart';

/// Per-chapter mining progress for Stage C resumability.
///
/// `bulkUpsertVariants` is upsert with `count += 1` semantics, so re-running
/// a chapter would double-count its votes. We therefore record each
/// successfully mined chapter here and skip it on subsequent runs until the
/// user explicitly resets the pipeline.
class MiningProgressDao extends BaseDao {
  MiningProgressDao();

  static const String table = 'tb_mining_progress';

  Future<Set<int>> selectMinedChapterIds(int bookId) async {
    final rows = await rawQueryList(
      'SELECT source_chapter_id FROM $table WHERE book_id = ?',
      arguments: [bookId],
      mapper: (row) => row['source_chapter_id'] as int,
    );
    return rows.toSet();
  }

  Future<void> markMined(int bookId, int sourceChapterId) async {
    await insert(
      table,
      {
        'book_id': bookId,
        'source_chapter_id': sourceChapterId,
        'mined_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deleteByBookId(int bookId) async {
    await delete(
      table,
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
  }
}

final miningProgressDao = MiningProgressDao();
