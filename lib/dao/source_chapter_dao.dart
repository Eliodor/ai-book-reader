import 'package:ai_book_reader/dao/base_dao.dart';
import 'package:ai_book_reader/models/chapter_status.dart';
import 'package:ai_book_reader/models/source_chapter.dart';
import 'package:sqflite/sqflite.dart';

class SourceChapterDao extends BaseDao {
  SourceChapterDao();

  static const String table = 'tb_source_chapters';

  Future<int> save(SourceChapter chapter) async {
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

    final existing =
        await selectByBookIdAndOrder(chapter.bookId, chapter.orderIndex);
    if (existing != null) {
      existing.title = chapter.title;
      existing.content = chapter.content;
      existing.status = chapter.status;
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

    final id = await insert(
      table,
      chapter.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    chapter.id = id;
    return id;
  }

  Future<SourceChapter?> selectById(int id) {
    return querySingle(
      table,
      mapper: SourceChapter.fromDb,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<SourceChapter?> selectByBookIdAndOrder(int bookId, int orderIndex) {
    return querySingle(
      table,
      mapper: SourceChapter.fromDb,
      where: 'book_id = ? AND order_index = ?',
      whereArgs: [bookId, orderIndex],
    );
  }

  Future<List<SourceChapter>> selectByBookId(int bookId) {
    return queryList(
      table,
      mapper: SourceChapter.fromDb,
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'order_index ASC',
    );
  }

  Future<List<SourceChapter>> selectByStatus(
      int bookId, ChapterStatus status) {
    return queryList(
      table,
      mapper: SourceChapter.fromDb,
      where: 'book_id = ? AND status = ?',
      whereArgs: [bookId, status.dbValue],
      orderBy: 'order_index ASC',
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

  Future<void> updateStatus(int id, ChapterStatus status) async {
    await update(
      table,
      {
        'status': status.dbValue,
        'update_time': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
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

final sourceChapterDao = SourceChapterDao();
