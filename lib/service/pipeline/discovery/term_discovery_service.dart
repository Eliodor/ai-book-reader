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
import 'package:flutter/foundation.dart' show compute;

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

class DiscoveryFailed extends DiscoveryOutcome {
  const DiscoveryFailed({required this.error, required this.stage});
  final Object error;
  final String stage;
}

/// Orchestrates Stage A discovery for one book.
///
/// 1. Reads `tb_source_chapters` for the book.
/// 2. Detects language via stopwords-iso.
/// 3. Spawns an isolate (`compute(runDiscoveryAll, …)`) that runs the 6-stage
///    pipeline on a snapshot of the chapter content.
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

  Future<DiscoveryOutcome> discoverIfNeeded({
    required int bookId,
    int topN = defaultDiscoveryTopN,
    void Function(String stage)? onStageChange,
  }) async {
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

    final DiscoveryOutput output;
    try {
      output = await compute(runDiscoveryAll, input);
    } catch (e, st) {
      AnxLog.severe('Term discovery isolate failed: $e\n$st');
      return DiscoveryFailed(error: e, stage: 'discover');
    }

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
      'raw=${output.stats.rawCandidateCount} final=${output.stats.finalCandidateCount} '
      'tokenize=${output.stats.tokenizeMs}ms gen=${output.stats.candidateGenMs}ms '
      'cvalue=${output.stats.cValueMs}ms dp=${output.stats.dispersionMs}ms '
      'cluster=${output.stats.clusterMs}ms sub=${output.stats.substringMs}ms '
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

final termDiscoveryService = TermDiscoveryService();
