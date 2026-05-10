import 'package:ai_book_reader/dao/base_dao.dart';
import 'package:ai_book_reader/models/reference_chapter.dart';

class ReferenceChapterDao extends BaseDao {
  ReferenceChapterDao();

  static const String table = 'tb_reference_chapters';

  /// Inserts a batch of chapters in a single SQL transaction (one fsync).
  /// Roughly 50–100× faster than [save] in a loop for hundreds of rows. The
  /// caller must ensure `(reference_translation_id, order_index)` is unique
  /// across the batch.
  Future<void> saveAll(List<ReferenceChapter> chapters) async {
    if (chapters.isEmpty) return;
    await transaction((txn) async {
      final batch = txn.batch();
      for (final ch in chapters) {
        batch.insert(table, ch.toMap());
      }
      await batch.commit(noResult: true);
    });
  }

  Future<int> save(ReferenceChapter chapter) async {
    final now = DateTime.now();
    if (chapter.id != null) {
      chapter.updateTime = now;
      await update(
        table,
        chapter.toMap(),
        where: 'id = ?',
        whereArgs: [chapter.id],
      );
      return chapter.id!;
    }
    final existing = await selectByTranslationIdAndOrder(
      chapter.referenceTranslationId,
      chapter.orderIndex,
    );
    if (existing != null) {
      existing.title = chapter.title;
      existing.chapterNumber = chapter.chapterNumber;
      existing.content = chapter.content;
      existing.meta = chapter.meta;
      existing.updateTime = now;
      await update(
        table,
        existing.toMap(),
        where: 'id = ?',
        whereArgs: [existing.id],
      );
      return existing.id!;
    }
    final id = await insert(table, chapter.toMap());
    chapter.id = id;
    return id;
  }

  Future<ReferenceChapter?> selectByTranslationIdAndOrder(
    int referenceTranslationId,
    int orderIndex,
  ) {
    return querySingle(
      table,
      mapper: ReferenceChapter.fromDb,
      where: 'reference_translation_id = ? AND order_index = ?',
      whereArgs: [referenceTranslationId, orderIndex],
    );
  }

  Future<List<ReferenceChapter>> selectByTranslationId(
    int referenceTranslationId,
  ) {
    return queryList(
      table,
      mapper: ReferenceChapter.fromDb,
      where: 'reference_translation_id = ?',
      whereArgs: [referenceTranslationId],
      orderBy: 'order_index ASC',
    );
  }

  Future<int> countByTranslationId(int referenceTranslationId) async {
    final row = await rawQuerySingle(
      'SELECT COUNT(*) AS c FROM $table WHERE reference_translation_id = ?',
      arguments: [referenceTranslationId],
      mapper: (r) => (r['c'] as int?) ?? 0,
    );
    return row ?? 0;
  }

  Future<void> deleteByTranslationId(int referenceTranslationId) async {
    await delete(
      table,
      where: 'reference_translation_id = ?',
      whereArgs: [referenceTranslationId],
    );
  }

  /// Returns rows joined with their original-language counterpart by
  /// `chapter_number`. Both sides must have a non-null number to appear.
  ///
  /// The result is a list of `(sourceTitle, sourceContent, refTitle,
  /// refContent, chapterNumber)` tuples — kept as plain maps so callers can
  /// pick what they need without locking into a specific model.
  Future<List<Map<String, Object?>>> selectAlignedWithSource(int bookId) async {
    return rawQueryList(
      '''
      SELECT
        s.id          AS source_id,
        s.title       AS source_title,
        s.content     AS source_content,
        r.id          AS reference_id,
        r.title       AS reference_title,
        r.content     AS reference_content,
        s.chapter_number AS chapter_number
      FROM tb_source_chapters s
      INNER JOIN tb_reference_chapters r
        ON r.book_id = s.book_id
       AND r.chapter_number = s.chapter_number
      WHERE s.book_id = ?
        AND s.chapter_number IS NOT NULL
      ORDER BY s.chapter_number ASC
      ''',
      arguments: [bookId],
      mapper: (row) => row,
    );
  }
}

final referenceChapterDao = ReferenceChapterDao();
