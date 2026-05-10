import 'dart:io';

import 'package:ai_book_reader/dao/source_chapter_dao.dart';
import 'package:ai_book_reader/models/chapter_status.dart';
import 'package:ai_book_reader/models/source_chapter.dart';
import 'package:ai_book_reader/service/pipeline/book_file_parser.dart';
import 'package:ai_book_reader/service/pipeline/chapter_merger.dart';
import 'package:ai_book_reader/utils/log/common.dart';

/// Outcome of a [ChapterParserService.parseBookIfNeeded] run.
sealed class ChapterParsingOutcome {
  const ChapterParsingOutcome();
}

class ChapterParsingSkipped extends ChapterParsingOutcome {
  const ChapterParsingSkipped(this.reason);
  final String reason;
}

class ChapterParsingCompleted extends ChapterParsingOutcome {
  const ChapterParsingCompleted({required this.total});
  final int total;
}

class ChapterParsingAborted extends ChapterParsingOutcome {
  const ChapterParsingAborted({
    required this.error,
    required this.done,
    required this.total,
  });
  final Object error;
  final int done;
  final int total;
}

/// First-time chapter parser. Reads the original book file directly with
/// [BookFileParser] (FB2 / EPUB), runs the result through [ChapterMerger]
/// (sub-chapter aggregation + `chapter_number` extraction), and writes one
/// row per chapter into `tb_source_chapters`.
///
/// No WebView, no foliate-js JS bridge. Idempotent: skips when source chapters
/// for the book already exist with non-empty content.
class ChapterParserService {
  ChapterParserService({SourceChapterDao? dao})
      : _dao = dao ?? sourceChapterDao;

  final SourceChapterDao _dao;

  Future<ChapterParsingOutcome> parseBookIfNeeded({
    required int bookId,
    required File file,
    void Function(int done, int total)? onProgress,
  }) async {
    final existing = await _dao.countByBookId(bookId);
    if (existing > 0) {
      final rows = await _dao.selectByBookId(bookId);
      final allEmpty = rows.every((c) => c.content.trim().isEmpty);
      if (!allEmpty) {
        return const ChapterParsingSkipped('already-parsed');
      }
      AnxLog.info(
        'Chapter parsing: existing rows for book $bookId are all empty, re-parsing',
      );
      await _dao.deleteByBookId(bookId);
    }

    if (!isParseableBookFormat(file.path)) {
      return const ChapterParsingSkipped('unsupported-format');
    }
    if (!await file.exists()) {
      return ChapterParsingAborted(
        error: StateError('Book file does not exist: ${file.path}'),
        done: 0,
        total: 0,
      );
    }

    final List<RawChapter> raws;
    try {
      raws = await BookFileParser.extractRawChapters(file);
    } catch (error, stack) {
      AnxLog.severe(
        'ChapterParser: extraction failed for book $bookId: $error\n$stack',
      );
      return ChapterParsingAborted(error: error, done: 0, total: 0);
    }

    if (raws.isEmpty) {
      return const ChapterParsingSkipped('no-chapters');
    }

    final merged = ChapterMerger.merge(raws);
    onProgress?.call(0, merged.length);

    final rows = <SourceChapter>[];
    for (var i = 0; i < merged.length; i++) {
      final m = merged[i];
      rows.add(SourceChapter(
        bookId: bookId,
        title: m.title.isEmpty ? 'Chapter ${i + 1}' : m.title,
        orderIndex: i,
        chapterNumber: m.chapterNumber,
        content: m.content,
        status: ChapterStatus.parsed,
        meta: m.metaJson,
      ));
    }

    try {
      await _dao.saveAll(rows);
    } catch (error, stack) {
      AnxLog.severe('Chapter parsing batch save failed: $error\n$stack');
      return ChapterParsingAborted(
        error: error,
        done: 0,
        total: merged.length,
      );
    }
    onProgress?.call(merged.length, merged.length);
    return ChapterParsingCompleted(total: merged.length);
  }

  /// Backfills `chapter_number` for source chapters that were saved before
  /// the v10 migration. Idempotent. Returns the number of rows updated.
  Future<int> backfillChapterNumbersForBook(int bookId) {
    return _dao.backfillChapterNumbers(bookId);
  }
}
