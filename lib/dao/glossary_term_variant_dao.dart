import 'package:ai_book_reader/dao/base_dao.dart';
import 'package:ai_book_reader/models/glossary_term_variant.dart';

class GlossaryTermVariantDao extends BaseDao {
  GlossaryTermVariantDao();

  static const String table = 'tb_glossary_term_variants';

  /// Increments the vote count for an existing `(book_id, term_source,
  /// term_target_normalized)` row, or inserts a new variant with count=1.
  /// Implemented as upsert through `INSERT ... ON CONFLICT ... DO UPDATE` so
  /// concurrent mining chapters never race past each other.
  Future<void> upsertVariant({
    required int bookId,
    required String termSource,
    required String termTargetNormalized,
    required String termTargetDisplay,
    int? firstChapterId,
  }) async {
    final now = DateTime.now().toIso8601String();
    final db = await database;
    await db.rawInsert(
      _upsertSql,
      [
        bookId,
        termSource,
        termTargetNormalized,
        termTargetDisplay,
        firstChapterId,
        now,
        now,
      ],
    );
  }

  /// Bulk variant of [upsertVariant] — applies every entry in a single
  /// transaction, so a chapter's worth of pairs hits sqflite once instead of
  /// once per pair.
  Future<void> bulkUpsertVariants(List<VariantUpsert> rows) async {
    if (rows.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    await transaction((txn) async {
      final batch = txn.batch();
      for (final r in rows) {
        batch.rawInsert(_upsertSql, [
          r.bookId,
          r.termSource,
          r.termTargetNormalized,
          r.termTargetDisplay,
          r.firstChapterId,
          now,
          now,
        ]);
      }
      await batch.commit(noResult: true);
    });
  }

  static const String _upsertSql = '''
    INSERT INTO $table
      (book_id, term_source, term_target_normalized, term_target_display,
       count, first_chapter_id, create_time, update_time)
    VALUES (?, ?, ?, ?, 1, ?, ?, ?)
    ON CONFLICT (book_id, term_source, term_target_normalized) DO UPDATE SET
      count = count + 1,
      update_time = excluded.update_time
    ''';

  Future<List<GlossaryTermVariant>> selectVariantsForSource(
    int bookId,
    String termSource,
  ) {
    return queryList(
      table,
      mapper: GlossaryTermVariant.fromDb,
      where: 'book_id = ? AND term_source = ?',
      whereArgs: [bookId, termSource],
      orderBy: 'count DESC, create_time ASC',
    );
  }

  /// For each `term_source` in the book returns the winning variant (highest
  /// count, earliest insertion as tie-breaker). Used by Stage C aggregation
  /// to promote winners to `tb_glossary_terms`.
  Future<List<GlossaryTermVariant>> aggregateWinners(int bookId) async {
    final rows = await rawQueryList(
      '''
      SELECT v.*
      FROM $table v
      INNER JOIN (
        SELECT term_source, MAX(count) AS max_count
        FROM $table
        WHERE book_id = ?
        GROUP BY term_source
      ) m
        ON v.term_source = m.term_source AND v.count = m.max_count
      WHERE v.book_id = ?
      GROUP BY v.term_source
      ORDER BY v.term_source ASC
      ''',
      arguments: [bookId, bookId],
      mapper: GlossaryTermVariant.fromDb,
    );
    return rows;
  }

  Future<int> countByBookId(int bookId) async {
    final row = await rawQuerySingle(
      'SELECT COUNT(*) AS c FROM $table WHERE book_id = ?',
      arguments: [bookId],
      mapper: (row) => (row['c'] as int?) ?? 0,
    );
    return row ?? 0;
  }

  Future<void> deleteByBookId(int bookId) async {
    await delete(
      table,
      where: 'book_id = ?',
      whereArgs: [bookId],
    );
  }
}

final glossaryTermVariantDao = GlossaryTermVariantDao();

class VariantUpsert {
  const VariantUpsert({
    required this.bookId,
    required this.termSource,
    required this.termTargetNormalized,
    required this.termTargetDisplay,
    this.firstChapterId,
  });
  final int bookId;
  final String termSource;
  final String termTargetNormalized;
  final String termTargetDisplay;
  final int? firstChapterId;
}
