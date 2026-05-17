import 'dart:async';
import 'dart:isolate';

import 'package:ai_book_reader/dao/source_chapter_dao.dart';
import 'package:ai_book_reader/dao/term_candidate_dao.dart';
import 'package:ai_book_reader/dao/term_candidate_occurrence_dao.dart';
import 'package:ai_book_reader/models/candidate_status.dart';
import 'package:ai_book_reader/models/candidate_type.dart';
import 'package:ai_book_reader/models/term_candidate.dart';
import 'package:ai_book_reader/models/term_candidate_occurrence.dart';
import 'package:ai_book_reader/service/pipeline/discovery/language_detector.dart';
import 'package:ai_book_reader/service/pipeline/discovery/raw_models.dart';
import 'package:ai_book_reader/service/pipeline/discovery/stopwords_loader.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_constants.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_isolate.dart';
import 'package:ai_book_reader/service/pipeline/discovery/tokenizer.dart';
import 'package:ai_book_reader/utils/log/common.dart';

sealed class DiscoveryOutcome {
  const DiscoveryOutcome();
}

class DiscoverySkipped extends DiscoveryOutcome {
  const DiscoverySkipped(this.reason);
  final String reason;
}

class DiscoveryCompleted extends DiscoveryOutcome {
  const DiscoveryCompleted({
    required this.candidatesWritten,
    required this.occurrencesWritten,
    required this.sourceLanguage,
    required this.fallbackLanguage,
    required this.totalMs,
  });

  final int candidatesWritten;
  final int occurrencesWritten;
  final String sourceLanguage;
  final bool fallbackLanguage;
  final int totalMs;
}

class DiscoveryCancelled extends DiscoveryOutcome {
  const DiscoveryCancelled();
}

class DiscoveryFailed extends DiscoveryOutcome {
  const DiscoveryFailed({required this.error, required this.stage});
  final Object error;
  final String stage;
}

/// Orchestrates Stage A discovery for one book.
///
/// 1. Reads `tb_source_chapters` for the book.
/// 2. Detects language via stopwords-iso.
/// 3. Spawns an isolate (`Isolate.spawn(discoveryIsolateEntry, …)`) that runs
///    the 6-stage pipeline on a snapshot of the chapter content. The isolate
///    accepts a cancellation signal over a [SendPort].
/// 4. Persists candidates + occurrences in a single transaction via DAOs.
///
/// Idempotent: skips if candidates already exist for the book (use the public
/// `resetForBook` to wipe and re-run).
class TermDiscoveryService {
  TermDiscoveryService({
    TermCandidateDao? candidateDao,
    TermCandidateOccurrenceDao? occurrenceDao,
    SourceChapterDao? chapterDao,
    StopwordsLoader? stopwords,
  })  : _candidateDao = candidateDao ?? termCandidateDao,
        _occurrenceDao = occurrenceDao ?? termCandidateOccurrenceDao,
        _chapterDao = chapterDao ?? sourceChapterDao,
        _stopwords = stopwords ?? stopwordsLoader;

  final TermCandidateDao _candidateDao;
  final TermCandidateOccurrenceDao _occurrenceDao;
  final SourceChapterDao _chapterDao;
  final StopwordsLoader _stopwords;

  SendPort? _activeCancelPort;
  bool _cancelRequested = false;

  /// Request cancellation of any active discovery isolate. Safe to call from
  /// any isolate — the signal is forwarded to the worker once it has reported
  /// its cancel port back to us.
  void cancel() {
    _cancelRequested = true;
    final port = _activeCancelPort;
    if (port != null) {
      try {
        port.send(discoveryCancelSignal);
      } catch (e) {
        AnxLog.warning('Term discovery cancel send failed: $e');
      }
    }
  }

  Future<DiscoveryOutcome> discoverIfNeeded({
    required int bookId,
    int topN = defaultDiscoveryTopN,
    void Function(String stage)? onStageChange,
  }) async {
    _cancelRequested = false;
    _activeCancelPort = null;

    final existing = await _candidateDao.countByBookId(bookId);
    if (existing > 0) {
      return const DiscoverySkipped('already-discovered');
    }

    onStageChange?.call('load-chapters');
    final chapters = await _chapterDao.selectByBookId(bookId);
    if (chapters.isEmpty) {
      return const DiscoverySkipped('no-source-chapters');
    }

    final snapshots = chapters
        .where((c) => c.content.trim().isNotEmpty)
        .map((c) => ChapterSnapshot(
              id: c.id ?? -1,
              orderIndex: c.orderIndex,
              content: c.content,
            ))
        .where((s) => s.id >= 0)
        .toList(growable: false);
    if (snapshots.isEmpty) {
      return const DiscoverySkipped('chapters-empty');
    }

    onStageChange?.call('detect-language');
    Map<String, Set<String>> allStopwords;
    try {
      allStopwords = await _stopwords.loadAll();
    } catch (e, st) {
      AnxLog.severe('Term discovery: stopwords load failed: $e\n$st');
      allStopwords = const {};
    }

    final detection = _detectFromFirstChapters(snapshots, allStopwords);
    final stopwordsForLang = allStopwords[detection.languageCode] ?? const {};

    onStageChange?.call('discover');
    final input = DiscoveryInput(
      chapters: snapshots,
      sourceLanguage: detection.languageCode,
      stopwords: stopwordsForLang,
      topN: topN,
    );

    final _IsolateRunResult runResult;
    try {
      runResult = await _runIsolate(input);
    } catch (e, st) {
      AnxLog.severe('Term discovery isolate failed: $e\n$st');
      return DiscoveryFailed(error: e, stage: 'discover');
    }

    if (runResult.cancelled) {
      AnxLog.info('Term discovery cancelled for book $bookId');
      return const DiscoveryCancelled();
    }

    final DiscoveryOutput output = runResult.output!;

    onStageChange?.call('persist');
    try {
      await _persistResults(bookId, output);
    } catch (e, st) {
      AnxLog.severe('Term discovery persist failed: $e\n$st');
      return DiscoveryFailed(error: e, stage: 'persist');
    }

    AnxLog.info(
      'Term discovery: book=$bookId lang=${detection.languageCode} '
      'fallback=${detection.isFallback} '
      'raw=${output.stats.rawCandidateCount} '
      'prefiltered=${output.stats.prefilteredCount} '
      'final=${output.stats.finalCandidateCount} '
      'tokenize=${output.stats.tokenizeMs}ms gen=${output.stats.candidateGenMs}ms '
      'prefilter=${output.stats.prefilterMs}ms '
      'cvalue=${output.stats.cValueMs}ms cluster=${output.stats.clusterMs}ms '
      'dp=${output.stats.dispersionMs}ms sub=${output.stats.substringMs}ms '
      'total=${output.stats.totalMs}ms',
    );

    return DiscoveryCompleted(
      candidatesWritten: output.candidates.length,
      occurrencesWritten: output.occurrences.length,
      sourceLanguage: detection.languageCode,
      fallbackLanguage: detection.isFallback,
      totalMs: output.stats.totalMs,
    );
  }

  Future<_IsolateRunResult> _runIsolate(DiscoveryInput input) async {
    final completer = Completer<_IsolateRunResult>();
    final mainPort = ReceivePort();
    Isolate? isolate;

    final sub = mainPort.listen((msg) {
      if (msg is DiscoveryIsolateReady) {
        _activeCancelPort = msg.cancelPort;
        // If cancel was requested before the worker came up, forward it now.
        if (_cancelRequested) {
          try {
            msg.cancelPort.send(discoveryCancelSignal);
          } catch (e) {
            AnxLog.warning('Term discovery cancel re-send failed: $e');
          }
        }
        return;
      }
      if (msg is DiscoveryIsolateResult) {
        if (!completer.isCompleted) {
          completer.complete(_IsolateRunResult.ok(msg.output));
        }
        return;
      }
      if (msg == discoveryCancelledResult) {
        if (!completer.isCompleted) {
          completer.complete(_IsolateRunResult.cancelled());
        }
        return;
      }
      if (msg is DiscoveryIsolateError) {
        if (!completer.isCompleted) {
          completer.completeError(msg.error, msg.stackTrace);
        }
        return;
      }
    });

    try {
      isolate = await Isolate.spawn(
        discoveryIsolateEntry,
        DiscoverySpawnArgs(mainSendPort: mainPort.sendPort, input: input),
        errorsAreFatal: true,
      );
      return await completer.future;
    } finally {
      await sub.cancel();
      mainPort.close();
      isolate?.kill(priority: Isolate.beforeNextEvent);
      _activeCancelPort = null;
    }
  }

  Future<void> resetForBook(int bookId) async {
    await _occurrenceDao.deleteByBookId(bookId);
    await _candidateDao.deleteByBookId(bookId);
  }

  LanguageDetectionResult _detectFromFirstChapters(
    List<ChapterSnapshot> snapshots,
    Map<String, Set<String>> stopwords,
  ) {
    // Tokenize the first up to 3 chapters' worth of content for detection.
    final sample = <String>[];
    var charsCollected = 0;
    for (final ch in snapshots.take(3)) {
      final tokenized = tokenize(
        chapterId: ch.id,
        orderIndex: ch.orderIndex,
        content: ch.content,
      );
      for (final tok in tokenized.tokens) {
        sample.add(tok.normalizedText);
      }
      charsCollected += ch.content.length;
      if (charsCollected > 50000) break;
    }
    return detectLanguage(
      sampleTokens: sample,
      stopwordsByLang: stopwords,
    );
  }

  Future<void> _persistResults(int bookId, DiscoveryOutput output) async {
    if (output.candidates.isEmpty) return;
    final candidates = output.candidates
        .map((c) => TermCandidate(
              bookId: bookId,
              sourceText: c.sourceText,
              normalizedSource: c.normalizedSource,
              candidateType: CandidateType.fromDb(c.candidateType),
              score: c.score,
              frequencyTotal: c.frequencyTotal,
              chapterCount: c.chapterCount,
              firstChapterId: c.firstChapterId,
              status: CandidateStatus.candidate,
            ))
        .toList(growable: false);
    final ids = await _candidateDao.bulkSave(candidates);
    final keyToId = <String, int>{};
    for (var i = 0; i < candidates.length; i++) {
      keyToId[candidates[i].normalizedSource] = ids[i];
    }

    final occurrences = <TermCandidateOccurrence>[];
    for (final occ in output.occurrences) {
      final candidateId = keyToId[occ.normalizedSource];
      if (candidateId == null) continue;
      occurrences.add(TermCandidateOccurrence(
        candidateId: candidateId,
        chapterId: occ.chapterId,
        orderIndex: occ.orderIndex,
        position: occ.position,
        contextBefore: occ.contextBefore,
        contextAfter: occ.contextAfter,
      ));
    }
    await _occurrenceDao.bulkInsert(occurrences);
  }
}

class _IsolateRunResult {
  _IsolateRunResult._({this.output, required this.cancelled});

  factory _IsolateRunResult.ok(DiscoveryOutput output) =>
      _IsolateRunResult._(output: output, cancelled: false);

  factory _IsolateRunResult.cancelled() =>
      _IsolateRunResult._(output: null, cancelled: true);

  final DiscoveryOutput? output;
  final bool cancelled;
}

final termDiscoveryService = TermDiscoveryService();
