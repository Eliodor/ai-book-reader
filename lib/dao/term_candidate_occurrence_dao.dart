import 'package:ai_book_reader/dao/base_dao.dart';
import 'package:ai_book_reader/models/term_candidate_occurrence.dart';

class TermCandidateOccurrenceDao extends BaseDao {
  TermCandidateOccurrenceDao();

  static const String table = 'tb_term_candidate_occurrences';

  /// Batch insert occurrences after Stage A. ON DELETE CASCADE on the
  /// candidate FK takes care of cleanup when candidates are removed.
  Future<void> bulkInsert(List<TermCandidateOccurrence> rows) async {
    if (rows.isEmpty) return;
    await transaction((txn) async {
      final batch = txn.batch();
      for (final row in rows) {
        batch.insert(table, row.toMap());
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<TermCandidateOccurrence>> selectByCandidateId(
    int candidateId, {
    int? limit,
  }) {
    return queryList(
      table,
      mapper: TermCandidateOccurrence.fromDb,
      where: 'candidate_id = ?',
      whereArgs: [candidateId],
      orderBy: 'order_index ASC, id ASC',
      limit: limit,
    );
  }

  /// Returns `(candidate_id, chapter_id)` pairs for all candidates in
  /// [candidateIds] — used to build the coverage map for Stage C selector.
  Future<List<(int candidateId, int chapterId)>> selectCoveragePairs(
    List<int> candidateIds,
  ) async {
    if (candidateIds.isEmpty) return const [];
    final placeholders = List.filled(candidateIds.length, '?').join(',');
    final rows = await rawQueryList(
      'SELECT DISTINCT candidate_id, chapter_id FROM $table '
      'WHERE candidate_id IN ($placeholders)',
      arguments: candidateIds,
      mapper: (row) => (
        row['candidate_id'] as int,
        row['chapter_id'] as int,
      ),
    );
    return rows;
  }

  Future<void> deleteByBookId(int bookId) async {
    // Occurrences don't carry book_id directly. Join through candidates.
    final database = await this.database;
    await database.rawDelete(
      'DELETE FROM $table WHERE candidate_id IN '
      '(SELECT id FROM tb_term_candidates WHERE book_id = ?)',
      [bookId],
    );
  }
}

final termCandidateOccurrenceDao = TermCandidateOccurrenceDao();
