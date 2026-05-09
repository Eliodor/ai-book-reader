import 'package:ai_book_reader/dao/source_chapter_dao.dart';
import 'package:ai_book_reader/dao/target_chapter_dao.dart';
import 'package:ai_book_reader/models/chapter_status.dart';
import 'package:ai_book_reader/models/source_chapter.dart';
import 'package:ai_book_reader/models/target_chapter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'chapters.g.dart';

/// Lists every source-language chapter for a single book, ordered by
/// `order_index`.
///
/// Iteration 2 of the NovelTranslator port: like `Glossary`, this provider has
/// no UI yet — it exists so the pipeline services in later iterations can
/// already read/write through Riverpod.
@riverpod
class SourceChapters extends _$SourceChapters {
  @override
  Future<List<SourceChapter>> build(int bookId) {
    return sourceChapterDao.selectByBookId(bookId);
  }

  Future<int> upsert(SourceChapter chapter) async {
    final id = await sourceChapterDao.save(chapter);
    await refresh();
    return id;
  }

  Future<void> updateStatus(int id, ChapterStatus status) async {
    await sourceChapterDao.updateStatus(id, status);
    await refresh();
  }

  Future<void> remove(int id) async {
    await sourceChapterDao.deleteById(id);
    await refresh();
  }

  Future<void> clear() async {
    await sourceChapterDao.deleteByBookId(bookId);
    await refresh();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final chapters = await sourceChapterDao.selectByBookId(bookId);
      state = AsyncValue.data(chapters);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }
}

/// Lists every translated chapter for a single book, ordered by `order_index`.
@riverpod
class TargetChapters extends _$TargetChapters {
  @override
  Future<List<TargetChapter>> build(int bookId) {
    return targetChapterDao.selectByBookId(bookId);
  }

  Future<int> upsert(TargetChapter chapter) async {
    final id = await targetChapterDao.save(chapter);
    await refresh();
    return id;
  }

  Future<void> updateStatus(int id, ChapterStatus status) async {
    await targetChapterDao.updateStatus(id, status);
    await refresh();
  }

  Future<void> remove(int id) async {
    await targetChapterDao.deleteById(id);
    await refresh();
  }

  Future<void> clear() async {
    await targetChapterDao.deleteByBookId(bookId);
    await refresh();
  }

  Future<void> refresh() async {
    state = const AsyncValue.loading();
    try {
      final chapters = await targetChapterDao.selectByBookId(bookId);
      state = AsyncValue.data(chapters);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }
}
