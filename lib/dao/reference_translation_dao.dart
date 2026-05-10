import 'package:ai_book_reader/dao/base_dao.dart';
import 'package:ai_book_reader/dao/reference_chapter_dao.dart';
import 'package:ai_book_reader/models/reference_translation.dart';

class ReferenceTranslationDao extends BaseDao {
  ReferenceTranslationDao();

  static const String table = 'tb_reference_translations';

  Future<int> save(ReferenceTranslation row) async {
    final now = DateTime.now();
    if (row.id != null) {
      row.updateTime = now;
      await update(
        table,
        row.toMap(),
        where: 'id = ?',
        whereArgs: [row.id],
      );
      return row.id!;
    }
    final id = await insert(table, row.toMap());
    row.id = id;
    return id;
  }

  Future<ReferenceTranslation?> selectById(int id) {
    return querySingle(
      table,
      mapper: ReferenceTranslation.fromDb,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<ReferenceTranslation>> selectByBookId(int bookId) {
    return queryList(
      table,
      mapper: ReferenceTranslation.fromDb,
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'part_order ASC',
    );
  }

  Future<int> countByBookId(int bookId) async {
    final row = await rawQuerySingle(
      'SELECT COUNT(*) AS c FROM $table WHERE book_id = ?',
      arguments: [bookId],
      mapper: (r) => (r['c'] as int?) ?? 0,
    );
    return row ?? 0;
  }

  Future<int> nextPartOrder(int bookId) async {
    final row = await rawQuerySingle(
      'SELECT MAX(part_order) AS m FROM $table WHERE book_id = ?',
      arguments: [bookId],
      mapper: (r) => r['m'] as int?,
    );
    if (row == null) return 0;
    return row + 1;
  }

  Future<void> updateStatus(
    int id,
    ReferenceParsingStatus status, {
    String? error,
  }) async {
    await update(
      table,
      {
        'parsing_status': status.dbValue,
        'parsing_error': error,
        'update_time': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Atomic delete: clears chapters first, then the parent row. The on-disk
  /// file is _not_ touched here — the caller is responsible for that, since
  /// the DAO has no notion of [getBasePath].
  Future<void> deleteById(int id) async {
    await transaction((txn) async {
      await txn.delete(
        ReferenceChapterDao.table,
        where: 'reference_translation_id = ?',
        whereArgs: [id],
      );
      await txn.delete(
        table,
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }
}

final referenceTranslationDao = ReferenceTranslationDao();
