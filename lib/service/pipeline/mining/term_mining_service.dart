import 'package:ai_book_reader/dao/glossary_term_dao.dart';
import 'package:ai_book_reader/dao/glossary_term_variant_dao.dart';
import 'package:ai_book_reader/dao/mining_progress_dao.dart';
import 'package:ai_book_reader/dao/source_chapter_dao.dart';
import 'package:ai_book_reader/dao/target_chapter_dao.dart';
import 'package:ai_book_reader/dao/term_candidate_dao.dart';
import 'package:ai_book_reader/dao/term_candidate_occurrence_dao.dart';
import 'package:ai_book_reader/models/candidate_status.dart';
import 'package:ai_book_reader/models/glossary_term.dart';
import 'package:ai_book_reader/models/source_chapter.dart';
import 'package:ai_book_reader/models/target_chapter.dart';
import 'package:ai_book_reader/models/term_candidate.dart';
import 'package:ai_book_reader/service/ai/ai_generate_once.dart';
import 'package:ai_book_reader/service/ai/ai_retry.dart';
import 'package:ai_book_reader/service/ai/index.dart';
import 'package:ai_book_reader/service/ai/json_response.dart';
import 'package:ai_book_reader/service/ai/locale_names.dart';
import 'package:ai_book_reader/service/ai/prompt_generate.dart';
import 'package:ai_book_reader/service/pipeline/mining/mining_chapter_selector.dart';
import 'package:ai_book_reader/service/pipeline/mining/mining_postfilter.dart';
import 'package:ai_book_reader/utils/log/common.dart';
import 'package:langchain_core/chat_models.dart';

sealed class MiningOutcome {
  const MiningOutcome();
}

class MiningSkipped extends MiningOutcome {
  const MiningSkipped(this.reason);
  final String reason;
}

class MiningCompleted extends MiningOutcome {
  const MiningCompleted({
    required this.chaptersProcessed,
    required this.variantsInserted,
    required this.glossaryWinners,
    required this.promotedCandidates,
  });
  final int chaptersProcessed;
  final int variantsInserted;
  final int glossaryWinners;
  final int promotedCandidates;
}

class MiningFailed extends MiningOutcome {
  const MiningFailed({required this.error, required this.stage});
  final Object error;
  final String stage;
}

class MiningCancelled extends MiningOutcome {
  const MiningCancelled();
}

/// Soft chapter-size limit (chars) before we split the chapter into halves.
const int _splitThresholdChars = 240000;

/// Stage C — pair mining over translated chapters.
///
/// Workflow:
/// 1. Read accepted + uncertain candidates and the chapter coverage map.
/// 2. Greedy set-cover to pick the chapters to mine (target 80% coverage).
/// 3. For each chapter, send (source, target, terms) to the LLM, parse the
///    JSON response, postfilter pairs, upsert into `tb_glossary_term_variants`
///    (count++ per `(book_id, term_source, term_target_normalized)`).
/// 4. After all chapters: aggregate winners (max count) and upsert into
///    `tb_glossary_terms`. Mark the corresponding candidates as `promoted`.
class TermMiningService {
  TermMiningService({
    TermCandidateDao? candidateDao,
    TermCandidateOccurrenceDao? occurrenceDao,
    SourceChapterDao? sourceDao,
    TargetChapterDao? targetDao,
    GlossaryTermVariantDao? variantDao,
    GlossaryTermDao? glossaryDao,
    MiningProgressDao? progressDao,
  })  : _candidateDao = candidateDao ?? termCandidateDao,
        _occurrenceDao = occurrenceDao ?? termCandidateOccurrenceDao,
        _sourceDao = sourceDao ?? sourceChapterDao,
        _targetDao = targetDao ?? targetChapterDao,
        _variantDao = variantDao ?? glossaryTermVariantDao,
        _glossaryDao = glossaryDao ?? glossaryTermDao,
        _progressDao = progressDao ?? miningProgressDao;

  final TermCandidateDao _candidateDao;
  final TermCandidateOccurrenceDao _occurrenceDao;
  final SourceChapterDao _sourceDao;
  final TargetChapterDao _targetDao;
  final GlossaryTermVariantDao _variantDao;
  final GlossaryTermDao _glossaryDao;
  final MiningProgressDao _progressDao;

  bool _cancelled = false;
  void cancel() {
    _cancelled = true;
    cancelActiveAiRequest();
  }

  void resetCancellation() => _cancelled = false;

  /// Mines glossary pairs for the book.
  ///
  /// `concurrency` defaults to 1 (sequential per-chapter). The plumbing for
  /// parallel workers is in place, but the underlying `CancelableLangchainRunner`
  /// (`lib/service/ai/langchain_runner.dart`) stores a single `_subscription`
  /// at module scope, so two concurrent streams trample each other's cancel
  /// handles. Once the runner supports multiple in-flight requests, raise this
  /// default to 3-4 for a ~3-5× wall-clock win on multi-chapter mining.
  Future<MiningOutcome> mineIfNeeded({
    required int bookId,
    required String fromLocale,
    required String toLocale,
    double targetCoverage = 80.0,
    int maxChapters = 0,
    int concurrency = 1,
    void Function(int done, int total)? onProgress,
    void Function(String stage)? onStageChange,
  }) async {
    resetCancellation();
    onStageChange?.call('load-candidates');
    final candidates = await _candidateDao.selectByStatuses(
      bookId,
      const [CandidateStatus.accepted, CandidateStatus.uncertain],
    );
    if (candidates.isEmpty) {
      return const MiningSkipped('no-accepted-candidates');
    }

    onStageChange?.call('build-coverage');
    final scores = <int, double>{};
    final byId = <int, TermCandidate>{};
    for (final c in candidates) {
      if (c.id == null) continue;
      scores[c.id!] = c.score;
      byId[c.id!] = c;
    }
    final pairs = await _occurrenceDao.selectCoveragePairs(scores.keys.toList());
    final chapterCoverage = <int, Set<int>>{};
    for (final p in pairs) {
      chapterCoverage.putIfAbsent(p.$2, () => <int>{}).add(p.$1);
    }

    if (chapterCoverage.isEmpty) {
      return const MiningSkipped('no-coverage');
    }

    final sourceChapters = await _sourceDao.selectByBookId(bookId);
    final sourceById = <int, SourceChapter>{
      for (final s in sourceChapters)
        if (s.id != null) s.id!: s,
    };
    final targetChapters = await _targetDao.selectByBookId(bookId);
    final targetBySource = <int, TargetChapter>{
      for (final t in targetChapters) t.sourceChapterId: t,
    };

    final chapterMeta = <int, ChapterMeta>{};
    for (final s in sourceChapters) {
      if (s.id == null) continue;
      // Only consider chapters that have a translated counterpart.
      if (!targetBySource.containsKey(s.id)) continue;
      chapterMeta[s.id!] = ChapterMeta(
        id: s.id!,
        orderIndex: s.orderIndex,
        title: s.title,
      );
    }
    // Drop chapter coverage entries that lack a translation.
    chapterCoverage.removeWhere((cid, _) => !chapterMeta.containsKey(cid));
    if (chapterCoverage.isEmpty) {
      return const MiningSkipped('no-translated-chapters');
    }

    onStageChange?.call('select-chapters');
    final selection = selectMiningChapters(
      candidateScores: scores,
      chapterCoverage: chapterCoverage,
      chapterMeta: chapterMeta,
      targetCoverage: targetCoverage,
      maxChapters: maxChapters,
    );
    AnxLog.info(
      'Term mining: selected ${selection.orderedChapterIds.length} chapter(s) '
      'for ${selection.coverage.toStringAsFixed(1)}% coverage',
    );

    onStageChange?.call('mine');
    final chapterIds = selection.orderedChapterIds;
    final total = chapterIds.length;
    final alreadyMined = await _progressDao.selectMinedChapterIds(bookId);
    onProgress?.call(0, total);

    var variantsInserted = 0;
    var chaptersProcessed = alreadyMined
        .where((id) => chapterIds.contains(id))
        .length;
    if (chaptersProcessed > 0) {
      AnxLog.info(
        'Term mining: resuming, skipping $chaptersProcessed/$total already-mined chapter(s)',
      );
      onProgress?.call(chaptersProcessed, total);
    }
    var cursor = 0;
    Object? failureError;
    int? failureChapterId;

    Future<void> worker() async {
      while (true) {
        if (_cancelled || failureError != null) return;
        final myIdx = cursor++;
        if (myIdx >= total) return;
        final chapterId = chapterIds[myIdx];
        if (alreadyMined.contains(chapterId)) continue;
        final source = sourceById[chapterId];
        final target = targetBySource[chapterId];
        if (source == null || target == null) {
          continue;
        }
        final candidatesHere = chapterCoverage[chapterId] ?? const <int>{};
        if (candidatesHere.isEmpty) continue;
        final terms = candidatesHere
            .map((id) => byId[id])
            .whereType<TermCandidate>()
            .where((c) => c.status != CandidateStatus.promoted)
            .toList();
        if (terms.isEmpty) {
          await _progressDao.markMined(bookId, chapterId);
          chaptersProcessed++;
          onProgress?.call(chaptersProcessed, total);
          continue;
        }
        try {
          final inserted = await _mineChapter(
            bookId: bookId,
            source: source,
            target: target,
            terms: terms,
            fromLocale: fromLocale,
            toLocale: toLocale,
          );
          variantsInserted += inserted;
          await _progressDao.markMined(bookId, chapterId);
        } catch (e, st) {
          AnxLog.severe('Mining chapter $chapterId failed: $e\n$st');
          failureError = e;
          failureChapterId = chapterId;
          return;
        }
        chaptersProcessed++;
        onProgress?.call(chaptersProcessed, total);
      }
    }

    final workers = List.generate(
      concurrency < 1 ? 1 : concurrency,
      (_) => worker(),
    );
    await Future.wait(workers);

    if (failureError != null) {
      return MiningFailed(
        error: failureError!,
        stage: 'mine-chapter:${failureChapterId ?? -1}',
      );
    }
    if (_cancelled) {
      return const MiningCancelled();
    }

    onStageChange?.call('aggregate');
    final winners = await _variantDao.aggregateWinners(bookId);
    var promoted = 0;
    for (final w in winners) {
      await _glossaryDao.save(GlossaryTerm(
        bookId: bookId,
        termSource: w.termSource,
        termTarget: w.termTargetDisplay,
        sourceChapterId: w.firstChapterId,
      ));
      await _candidateDao.markPromoted(
        bookId: bookId,
        normalizedSource: w.termSource.toLowerCase(),
      );
      promoted++;
    }

    return MiningCompleted(
      chaptersProcessed: chaptersProcessed,
      variantsInserted: variantsInserted,
      glossaryWinners: winners.length,
      promotedCandidates: promoted,
    );
  }

  Future<int> _mineChapter({
    required int bookId,
    required SourceChapter source,
    required TargetChapter target,
    required List<TermCandidate> terms,
    required String fromLocale,
    required String toLocale,
  }) async {
    final termsByText = <String, TermCandidate>{
      for (final t in terms) t.sourceText: t,
    };
    final termsList = terms.map((t) => '- ${t.sourceText}').join('\n');

    final pairs =
        await _runMiningChunked(source.content, target.content, fromLocale,
            toLocale, termsList);

    final upserts = <VariantUpsert>[];
    for (final entry in pairs.entries) {
      final src = entry.key;
      final tgt = entry.value;
      final filter = postfilterPair(source: src, target: tgt);
      if (!filter.keep) continue;
      final normalized = normalizeTargetKey(tgt!);
      if (normalized.isEmpty) continue;
      final candidate = termsByText[src];
      upserts.add(VariantUpsert(
        bookId: bookId,
        termSource: src,
        termTargetNormalized: normalized,
        termTargetDisplay: tgt.trim(),
        firstChapterId: candidate?.firstChapterId ?? source.id,
      ));
    }
    if (upserts.isNotEmpty) {
      await _variantDao.bulkUpsertVariants(upserts);
    }
    return upserts.length;
  }

  Future<Map<String, String?>> _runMiningChunked(
    String sourceContent,
    String targetContent,
    String fromLocale,
    String toLocale,
    String termsList,
  ) async {
    final totalLen = sourceContent.length + targetContent.length;
    if (totalLen <= _splitThresholdChars) {
      return _runMiningOnce(
          sourceContent, targetContent, fromLocale, toLocale, termsList);
    }
    // Split each side at the nearest paragraph boundary near the middle.
    final src1 = _splitAtParagraph(sourceContent, sourceContent.length ~/ 2);
    final tgt1 = _splitAtParagraph(targetContent, targetContent.length ~/ 2);
    final result = <String, String?>{};
    final first = await _runMiningOnce(
      sourceContent.substring(0, src1),
      targetContent.substring(0, tgt1),
      fromLocale,
      toLocale,
      termsList,
    );
    final second = await _runMiningOnce(
      sourceContent.substring(src1),
      targetContent.substring(tgt1),
      fromLocale,
      toLocale,
      termsList,
    );
    result.addAll(first);
    second.forEach((k, v) {
      if (v != null) result[k] = v;
    });
    return result;
  }

  Future<Map<String, String?>> _runMiningOnce(
    String sourceContent,
    String targetContent,
    String fromLocale,
    String toLocale,
    String termsList,
  ) async {
    // Translate raw ISO codes ("uk" / "de") into English language names
    // ("Ukrainian" / "German") for the prompt: weaker LLMs misread bare codes.
    final payload = generatePromptCandidateMining(
      sourceText: sourceContent,
      targetText: targetContent,
      fromLocale: localeToEnglishName(fromLocale),
      toLocale: localeToEnglishName(toLocale),
      termsList: termsList,
    );
    final raw = await _callWithRetry(payload.buildMessages());
    final parsed = extractStringMap(raw);
    return parsed ?? const <String, String?>{};
  }

  Future<String> _callWithRetry(List<ChatMessage> messages) {
    return retryOnTransient<String>(
      () => aiGenerateOnce(messages, identifier: 'candidateMining'),
      isCancelled: () => _cancelled,
      onCancelled: () => '',
    );
  }

  int _splitAtParagraph(String s, int target) {
    final newline = s.indexOf('\n\n', target);
    if (newline > 0) return newline;
    final singleNewline = s.indexOf('\n', target);
    if (singleNewline > 0) return singleNewline;
    return target;
  }
}

final termMiningService = TermMiningService();
