import 'package:ai_book_reader/dao/base_dao.dart';
import 'package:ai_book_reader/models/candidate_status.dart';
import 'package:ai_book_reader/models/term_candidate.dart';
import 'package:sqflite/sqflite.dart';

class TermCandidateDao extends BaseDao {
  TermCandidateDao();

  static const String table = 'tb_term_candidates';

  /// Inserts many candidates in a single transaction. Used by Stage A after
  /// the isolate finishes a discovery pass. Caller is responsible for
  /// uniqueness on `(book_id, normalized_source)`; conflicts replace the
  /// existing row.
  Future<List<int>> bulkSave(List<TermCandidate> candidates) async {
    if (candidates.isEmpty) return const [];
    final ids = <int>[];
    await transaction((txn) async {
      for (final c in candidates) {
        final id = await txn.insert(
          table,
          c.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        ids.add(id);
        c.id = id;
      }
    });
    return ids;
  }

  Future<TermCandidate?> selectById(int id) {
    return querySingle(
      table,
      mapper: TermCandidate.fromDb,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<TermCandidate>> selectByBookId(int bookId) {
    return queryList(
      table,
      mapper: TermCandidate.fromDb,
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'score DESC',
    );
  }

  Future<List<TermCandidate>> selectByStatus(
    int bookId,
    CandidateStatus status,
  ) {
    return queryList(
      table,
      mapper: TermCandidate.fromDb,
      where: 'book_id = ? AND status = ?',
      whereArgs: [bookId, status.dbValue],
      orderBy: 'score DESC',
    );
  }

  /// Selects all candidates whose status is in [statuses]. Useful for Stage C
  /// which wants both `accepted` and `uncertain` rows.
  Future<List<TermCandidate>> selectByStatuses(
    int bookId,
    List<CandidateStatus> statuses,
  ) async {
    if (statuses.isEmpty) return const [];
    final placeholders = List.filled(statuses.length, '?').join(',');
    return rawQueryList(
      'SELECT * FROM $table WHERE book_id = ? AND status IN ($placeholders) '
      'ORDER BY score DESC',
      arguments: [bookId, ...statuses.map((s) => s.dbValue)],
      mapper: TermCandidate.fromDb,
    );
  }

  Future<int> countByBookId(int bookId) async {
    final row = await rawQuerySingle(
      'SELECT COUNT(*) AS c FROM $table WHERE book_id = ?',
      arguments: [bookId],
      mapper: (row) => (row['c'] as int?) ?? 0,
    );
    return row ?? 0;
  }

  Future<int> countByStatus(int bookId, CandidateStatus status) async {
    final row = await rawQuerySingle(
      'SELECT COUNT(*) AS c FROM $table WHERE book_id = ? AND status = ?',
      arguments: [bookId, status.dbValue],
      mapper: (row) => (row['c'] as int?) ?? 0,
    );
    return row ?? 0;
  }

  /// Batch status update used by Stage B after each LLM filter call.
  Future<void> updateStatusBatch({
    required List<int> ids,
    required CandidateStatus status,
    String? llmVerdict,
    String? llmReason,
    DateTime? filteredAt,
  }) async {
    if (ids.isEmpty) return;
    final ts = (filteredAt ?? DateTime.now()).toIso8601String();
    await transaction((txn) async {
      final batch = txn.batch();
      for (final id in ids) {
        batch.update(
          table,
          {
            'status': status.dbValue,
            if (llmVerdict != null) 'llm_verdict': llmVerdict,
            if (llmReason != null) 'llm_reason': llmReason,
            'filtered_at': ts,
            'update_time': ts,
          },
          where: 'id = ?',
          whereArgs: [id],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Marks a candidate as promoted (Stage C wrote the winning translation to
  /// the glossary). Uses the normalised key so multiple morphological variants
  /// of the same term get marked together.
  Future<void> markPromoted({
    required int bookId,
    required String normalizedSource,
    DateTime? promotedAt,
  }) async {
    final ts = (promotedAt ?? DateTime.now()).toIso8601String();
    await update(
      table,
      {
        'status': CandidateStatus.promoted.dbValue,
        'promoted_at': ts,
        'update_time': ts,
      },
      where: 'book_id = ? AND normalized_source = ?',
      whereArgs: [bookId, normalizedSource],
    );
  }

  Future<void> deleteById(int id) async {
    await delete(
      table,
      where: 'id = ?',
      whereArgs: [id],
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

final termCandidateDao = TermCandidateDao();
