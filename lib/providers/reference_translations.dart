import 'dart:async';
import 'dart:io';

import 'package:ai_book_reader/dao/reference_translation_dao.dart';
import 'package:ai_book_reader/models/reference_translation.dart';
import 'package:ai_book_reader/service/md5_service.dart';
import 'package:ai_book_reader/service/pipeline/book_file_parser.dart';
import 'package:ai_book_reader/service/pipeline/chapter_parser_service.dart';
import 'package:ai_book_reader/service/pipeline/reference_translation_parser_service.dart';
import 'package:ai_book_reader/utils/get_path/get_base_path.dart';
import 'package:ai_book_reader/utils/log/common.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'reference_translations.g.dart';

sealed class ReferenceParsingProgress {
  const ReferenceParsingProgress();
}

class RefIdle extends ReferenceParsingProgress {
  const RefIdle();
}

class RefRunning extends ReferenceParsingProgress {
  const RefRunning({required this.done, required this.total});
  final int done;
  final int total;
}

class RefDone extends ReferenceParsingProgress {
  const RefDone({required this.total});
  final int total;
}

class RefFailed extends ReferenceParsingProgress {
  const RefFailed({
    required this.error,
    required this.done,
    required this.total,
  });
  final Object error;
  final int done;
  final int total;
}

class ReferenceTranslationView {
  const ReferenceTranslationView({
    required this.row,
    required this.progress,
  });

  final ReferenceTranslation row;
  final ReferenceParsingProgress progress;
}

class AddPartsResult {
  const AddPartsResult({required this.accepted, required this.skippedFormat});

  final int accepted;
  final int skippedFormat;
}

@Riverpod(keepAlive: true)
class ReferenceTranslations extends _$ReferenceTranslations {
  final _liveProgress = <int, ReferenceParsingProgress>{};
  Future<void> _chain = Future.value();
  final _parser = ReferenceTranslationParserService();
  final _sourceParser = ChapterParserService();

  @override
  Future<List<ReferenceTranslationView>> build(int bookId) async {
    AnxLog.info('ReferenceTranslations: build for bookId=$bookId');
    // Lazy-fill chapter_number on the original-language source rows. Cheap
    // and idempotent; runs once per provider lifetime per book.
    try {
      await _sourceParser.backfillChapterNumbersForBook(bookId);
    } catch (e) {
      AnxLog.warning(
        'ReferenceTranslations: source backfill failed for book $bookId: $e',
      );
    }
    // Recover zombie rows: any 'parsing' row without an in-flight task is the
    // residue of a previous crash / hot-restart and should be marked failed
    // so the UI shows a real state instead of an eternal spinner.
    final rows = await referenceTranslationDao.selectByBookId(bookId);
    for (final row in rows) {
      if (row.parsingStatus == ReferenceParsingStatus.parsing &&
          !_liveProgress.containsKey(row.id)) {
        AnxLog.warning(
          'ReferenceTranslations: marking zombie parsing row ${row.id} as failed',
        );
        await referenceTranslationDao.updateStatus(
          row.id!,
          ReferenceParsingStatus.failed,
          error: 'Interrupted by previous app session',
        );
      }
    }
    return _loadViews();
  }

  Future<List<ReferenceTranslationView>> _loadViews() async {
    final rows = await referenceTranslationDao.selectByBookId(bookId);
    return rows.map((r) {
      final live = _liveProgress[r.id];
      return ReferenceTranslationView(
        row: r,
        progress: live ?? _progressFromStatus(r.parsingStatus),
      );
    }).toList(growable: false);
  }

  ReferenceParsingProgress _progressFromStatus(ReferenceParsingStatus s) {
    return switch (s) {
      ReferenceParsingStatus.pending => const RefIdle(),
      ReferenceParsingStatus.parsing => const RefRunning(done: 0, total: 0),
      ReferenceParsingStatus.parsed => const RefDone(total: 0),
      ReferenceParsingStatus.failed => const RefFailed(
          error: 'Failed',
          done: 0,
          total: 0,
        ),
    };
  }

  Future<void> _refresh() async {
    final views = await _loadViews();
    state = AsyncData(views);
  }

  Future<R> _enqueue<R>(Future<R> Function() task) {
    final prev = _chain;
    final completer = Completer<R>();
    _chain = prev.then((_) async {
      try {
        completer.complete(await task());
      } catch (e, st) {
        AnxLog.severe(
          'ReferenceTranslations: queued task failed: $e\n$st',
        );
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Accepts a list of files dropped or picked by the user. Files whose
  /// extension is not `.epub`/`.fb2` are silently skipped (counted in the
  /// returned [AddPartsResult]). Each accepted file is enqueued to be parsed
  /// strictly serially (only one WebView2 instance is active at a time).
  Future<AddPartsResult> addParts(List<File> files) async {
    AnxLog.info(
      'ReferenceTranslations: addParts called with ${files.length} files for book $bookId',
    );
    var accepted = 0;
    var skipped = 0;
    for (final file in files) {
      if (!isParseableBookFormat(file.path)) {
        AnxLog.info(
          'ReferenceTranslations: skipping unsupported format ${file.path}',
        );
        skipped++;
        continue;
      }
      accepted++;
      // Enqueue but don't await each one — the call returns once the file is
      // copied + queued, while parsing finishes asynchronously. Errors are
      // captured into the failed-progress state and surface in the UI.
      unawaited(_enqueue(() => _ingestSingle(file)));
    }
    AnxLog.info(
      'ReferenceTranslations: addParts queued $accepted accepted, $skipped skipped',
    );
    return AddPartsResult(accepted: accepted, skippedFormat: skipped);
  }

  Future<void> _ingestSingle(File file) async {
    AnxLog.info('ReferenceTranslations: _ingestSingle starting for ${file.path}');
    final originalName = p.basename(file.path);
    final extension = p.extension(file.path).replaceFirst('.', '');
    final stem = p
        .basenameWithoutExtension(file.path)
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll('\n', '')
        .replaceAll('\r', '')
        .trim();
    final safeStem = stem.length > 30 ? stem.substring(0, 30) : stem;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final dbFilePath = 'file/$safeStem-$ts.$extension';
    final absoluteFilePath = getBasePath(dbFilePath);

    // Make sure the target directory exists.
    await Directory(p.dirname(absoluteFilePath)).create(recursive: true);
    await file.copy(absoluteFilePath);

    final md5 = await MD5Service.calculateFileMd5(absoluteFilePath);
    final partOrder = await referenceTranslationDao.nextPartOrder(bookId);

    final row = ReferenceTranslation(
      bookId: bookId,
      filePath: dbFilePath,
      fileName: originalName,
      md5: md5,
      partOrder: partOrder,
      parsingStatus: ReferenceParsingStatus.pending,
    );
    final id = await referenceTranslationDao.save(row);
    row.id = id;
    AnxLog.info('ReferenceTranslations: row inserted id=$id, dispatching parser');

    _liveProgress[id] = const RefIdle();
    await _refresh();

    await referenceTranslationDao.updateStatus(
      id,
      ReferenceParsingStatus.parsing,
    );
    _liveProgress[id] = const RefRunning(done: 0, total: 0);
    await _refresh();

    final outcome = await _parser
        .parseTranslation(
          referenceTranslationId: id,
          bookId: bookId,
          file: File(absoluteFilePath),
          onProgress: (done, total) async {
            _liveProgress[id] = RefRunning(done: done, total: total);
            await _refresh();
          },
        )
        .timeout(
      const Duration(minutes: 5),
      onTimeout: () => ReferenceParsingAborted(
        error: TimeoutException('Parsing exceeded 5 minutes'),
        done: 0,
        total: 0,
      ),
    );

    switch (outcome) {
      case ReferenceParsingCompleted(:final total):
        await referenceTranslationDao.updateStatus(
          id,
          ReferenceParsingStatus.parsed,
        );
        _liveProgress[id] = RefDone(total: total);
      case ReferenceParsingAborted(:final error, :final done, :final total):
        await referenceTranslationDao.updateStatus(
          id,
          ReferenceParsingStatus.failed,
          error: error.toString(),
        );
        _liveProgress[id] = RefFailed(error: error, done: done, total: total);
    }
    await _refresh();
  }

  Future<void> deletePart(int referenceTranslationId) async {
    await _enqueue(() async {
      final row =
          await referenceTranslationDao.selectById(referenceTranslationId);
      if (row == null) return;
      await referenceTranslationDao.deleteById(referenceTranslationId);
      try {
        final f = File(getBasePath(row.filePath));
        if (await f.exists()) await f.delete();
      } catch (e) {
        AnxLog.warning(
          'ReferenceTranslations: failed to delete file ${row.filePath}: $e',
        );
      }
      _liveProgress.remove(referenceTranslationId);
      await _refresh();
    });
  }
}
