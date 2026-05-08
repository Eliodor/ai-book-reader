import 'package:ai_book_reader/dao/base_dao.dart';
import 'package:ai_book_reader/models/glossary_term.dart';
import 'package:sqflite/sqflite.dart';

class GlossaryTermDao extends BaseDao {
  GlossaryTermDao();

  static const String table = 'tb_glossary_terms';

  Future<int> save(GlossaryTerm term) async {
    final now = DateTime.now();
    if (term.id != null) {
      term.updateTime = now;
      await update(
        table,
        term.toMap(),
        where: 'id = ?',
        whereArgs: [term.id],
      );
      return term.id!;
    }

    final existing =
        await selectByBookIdAndSource(term.bookId, term.termSource);
    if (existing != null) {
      existing.termTarget = term.termTarget;
      existing.sourceChapterId =
          term.sourceChapterId ?? existing.sourceChapterId;
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
      term.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    term.id = id;
    return id;
  }

  Future<GlossaryTerm?> selectById(int id) {
    return querySingle(
      table,
      mapper: GlossaryTerm.fromDb,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<GlossaryTerm?> selectByBookIdAndSource(
      int bookId, String termSource) {
    return querySingle(
      table,
      mapper: GlossaryTerm.fromDb,
      where: 'book_id = ? AND term_source = ?',
      whereArgs: [bookId, termSource],
    );
  }

  Future<List<GlossaryTerm>> selectByBookId(int bookId) {
    return queryList(
      table,
      mapper: GlossaryTerm.fromDb,
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'term_source COLLATE NOCASE ASC',
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

final glossaryTermDao = GlossaryTermDao();
