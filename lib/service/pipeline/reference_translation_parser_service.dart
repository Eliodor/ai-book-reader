import 'dart:async';
import 'dart:io';

import 'package:ai_book_reader/dao/reference_chapter_dao.dart';
import 'package:ai_book_reader/models/reference_chapter.dart';
import 'package:ai_book_reader/service/pipeline/book_file_parser.dart';
import 'package:ai_book_reader/service/pipeline/chapter_merger.dart';
import 'package:ai_book_reader/utils/log/common.dart';

sealed class ReferenceParsingOutcome {
  const ReferenceParsingOutcome();
}

class ReferenceParsingCompleted extends ReferenceParsingOutcome {
  const ReferenceParsingCompleted({required this.total});
  final int total;
}

class ReferenceParsingAborted extends ReferenceParsingOutcome {
  const ReferenceParsingAborted({
    required this.error,
    required this.done,
    required this.total,
  });
  final Object error;
  final int done;
  final int total;
}

/// Parses a reference-translation file into `tb_reference_chapters`.
/// Pure-Dart pipeline driven by [BookFileParser].
class ReferenceTranslationParserService {
  ReferenceTranslationParserService({ReferenceChapterDao? chapterDao})
      : _chapterDao = chapterDao ?? referenceChapterDao;

  final ReferenceChapterDao _chapterDao;

  Future<ReferenceParsingOutcome> parseTranslation({
    required int referenceTranslationId,
    required int bookId,
    required File file,
    void Function(int done, int total)? onProgress,
  }) async {
    AnxLog.info(
      'ReferenceTranslationParser: starting translationId=$referenceTranslationId, file=${file.path}',
    );

    var done = 0;
    var total = 0;
    try {
      if (!await file.exists()) {
        throw StateError('File no longer exists: ${file.path}');
      }
      final raws = await BookFileParser.extractRawChapters(file);
      total = raws.length;
      AnxLog.info(
        'ReferenceTranslationParser: extracted ${raws.length} raw chapters',
      );
      onProgress?.call(0, total);
      if (raws.isEmpty) {
        return const ReferenceParsingCompleted(total: 0);
      }

      final merged = ChapterMerger.merge(raws);
      AnxLog.info(
        'ReferenceTranslationParser: merged into ${merged.length} chapters',
      );

      await _chapterDao.deleteByTranslationId(referenceTranslationId);
      final rows = <ReferenceChapter>[];
      for (var i = 0; i < merged.length; i++) {
        final m = merged[i];
        rows.add(ReferenceChapter(
          referenceTranslationId: referenceTranslationId,
          bookId: bookId,
          title: m.title,
          orderIndex: i,
          chapterNumber: m.chapterNumber,
          content: m.content,
          meta: m.metaJson,
        ));
      }
      await _chapterDao.saveAll(rows);
      done = merged.length;
      onProgress?.call(merged.length, merged.length);

      AnxLog.info(
        'ReferenceTranslationParser: completed translationId=$referenceTranslationId, '
        'rawCount=${raws.length}, mergedCount=${merged.length}',
      );
      return ReferenceParsingCompleted(total: merged.length);
    } catch (error, stack) {
      AnxLog.severe(
        'ReferenceTranslationParser failed (translationId=$referenceTranslationId): $error\n$stack',
      );
      try {
        await _chapterDao.deleteByTranslationId(referenceTranslationId);
      } catch (_) {/* swallow */}
      return ReferenceParsingAborted(
        error: error,
        done: done,
        total: total,
      );
    }
  }
}
