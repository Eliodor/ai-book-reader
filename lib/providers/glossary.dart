import 'package:ai_book_reader/dao/glossary_term_dao.dart';
import 'package:ai_book_reader/models/glossary_term.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'glossary.g.dart';

/// Provides the glossary terms for one book, sorted by source term.
///
/// Iteration 1 of the NovelTranslator port: this provider has no UI yet.
/// It exists to verify the architecture absorbs new pipeline tables.
@riverpod
class Glossary extends _$Glossary {
  @override
  Future<List<GlossaryTerm>> build(int bookId) async {
    return glossaryTermDao.selectByBookId(bookId);
  }

  Future<void> upsert(GlossaryTerm term) async {
    await glossaryTermDao.save(term);
    await refresh();
  }

  Future<void> remove(int id) async {
    await glossaryTermDao.deleteById(id);
    await refresh();
  }

  Future<void> clear() async {
    await glossaryTermDao.deleteByBookId(bookId);
    await refresh();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final terms = await glossaryTermDao.selectByBookId(bookId);
      state = AsyncValue.data(terms);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }
}
