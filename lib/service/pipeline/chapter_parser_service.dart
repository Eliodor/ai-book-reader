import 'package:ai_book_reader/dao/source_chapter_dao.dart';
import 'package:ai_book_reader/models/chapter_status.dart';
import 'package:ai_book_reader/models/source_chapter.dart';
import 'package:ai_book_reader/models/toc_item.dart';
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

/// First-open chapter parser. Walks the foliate-js TOC, fetches plain-text
/// content of each chapter via the supplied [fetchChapterByHref] callback, and
/// writes one row per chapter to `tb_source_chapters`.
///
/// The service is deliberately decoupled from Riverpod and from the WebView:
/// callers inject a [SourceChapterDao] and a chapter-fetch closure. Progress
/// is reported via [onProgress]; the caller updates whatever provider it owns.
class ChapterParserService {
  ChapterParserService({SourceChapterDao? dao})
      : _dao = dao ?? sourceChapterDao;

  final SourceChapterDao _dao;

  /// Parses the book if no source chapters exist yet for [bookId].
  ///
  /// Idempotent: if `tb_source_chapters` already has rows with non-empty
  /// content for this book, returns [ChapterParsingSkipped] without touching
  /// the DB. If every existing row has empty content (typical of an aborted
  /// first run that hit `reader is not defined` before foliate-js was ready),
  /// the rows are dropped and parsing re-runs.
  Future<ChapterParsingOutcome> parseBookIfNeeded({
    required int bookId,
    required List<TocItem> toc,
    required Future<String> Function(String href) fetchChapterByHref,
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

    final flat = _flatten(toc);
    if (flat.isEmpty) {
      return const ChapterParsingSkipped('empty-toc');
    }

    onProgress?.call(0, flat.length);

    var done = 0;
    for (var i = 0; i < flat.length; i++) {
      final item = flat[i];
      try {
        final raw = await fetchChapterByHref(item.href);
        final text = raw.trim();
        await _dao.save(SourceChapter(
          bookId: bookId,
          title: item.label.trim().isEmpty
              ? 'Chapter ${i + 1}'
              : item.label.trim(),
          orderIndex: i,
          content: text,
          status: ChapterStatus.parsed,
        ));
        done = i + 1;
        onProgress?.call(done, flat.length);
      } catch (error, stack) {
        AnxLog.severe(
          'Chapter parsing failed at index $i (href=${item.href}): $error\n$stack',
        );
        return ChapterParsingAborted(
          error: error,
          done: done,
          total: flat.length,
        );
      }
    }

    final saved = await _dao.selectByBookId(bookId);
    final hasAnyContent = saved.any((c) => c.content.trim().isNotEmpty);
    if (!hasAnyContent) {
      AnxLog.severe(
        'Chapter parsing produced no content for book $bookId — '
        'foliate-js likely was not ready. Rolling back so the next open retries.',
      );
      await _dao.deleteByBookId(bookId);
      return ChapterParsingAborted(
        error: StateError('foliate-js returned empty content for every chapter'),
        done: 0,
        total: flat.length,
      );
    }

    return ChapterParsingCompleted(total: flat.length);
  }

  /// Depth-first flatten preserving TOC order; nested headings become sibling
  /// rows in `tb_source_chapters`. Items without an `href` are skipped because
  /// foliate cannot fetch their content.
  static List<TocItem> _flatten(List<TocItem> toc) {
    final out = <TocItem>[];
    void visit(TocItem item) {
      if (item.href.isNotEmpty) {
        out.add(item);
      }
      for (final sub in item.subitems) {
        visit(sub);
      }
    }

    for (final item in toc) {
      visit(item);
    }
    return out;
  }
}

/// Returns true if [filePath] points at an EPUB or FB2 file. Other formats are
/// out of scope for the iteration-3 parser (foliate-js can render them but the
/// translation pipeline focuses on EPUB/FB2 first).
bool isParseableBookFormat(String filePath) {
  final lower = filePath.toLowerCase();
  return lower.endsWith('.epub') || lower.endsWith('.fb2');
}
