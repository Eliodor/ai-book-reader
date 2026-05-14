import 'dart:async';
import 'dart:io';

import 'package:ai_book_reader/dao/term_candidate_dao.dart';
import 'package:ai_book_reader/dao/term_candidate_occurrence_dao.dart';
import 'package:ai_book_reader/models/candidate_status.dart';
import 'package:ai_book_reader/models/term_candidate.dart';
import 'package:ai_book_reader/service/ai/ai_generate_once.dart';
import 'package:ai_book_reader/service/ai/json_response.dart';
import 'package:ai_book_reader/service/ai/prompt_generate.dart';
import 'package:ai_book_reader/utils/log/common.dart';

sealed class FilterOutcome {
  const FilterOutcome();
}

class FilterSkipped extends FilterOutcome {
  const FilterSkipped(this.reason);
  final String reason;
}

class FilterCompleted extends FilterOutcome {
  const FilterCompleted({
    required this.accepted,
    required this.rejected,
    required this.uncertain,
    required this.batchesRun,
    required this.batchesFailedSoft,
  });
  final int accepted;
  final int rejected;
  final int uncertain;
  final int batchesRun;
  final int batchesFailedSoft; // counted as "no-removal" fallbacks
}

class FilterFailed extends FilterOutcome {
  const FilterFailed({required this.error});
  final Object error;
}

/// Stage B — LLM filter over discovery candidates.
///
/// Reads `status='candidate'` rows, sends them to the LLM in batches of
/// [batchSize] (default 100), parses a JSON array of "indexes to remove" from
/// the response, and updates statuses to `accepted` / `rejected` / `uncertain`.
class TermFilterService {
  TermFilterService({
    TermCandidateDao? candidateDao,
    TermCandidateOccurrenceDao? occurrenceDao,
    int batchSize = 100,
    int minBatchSize = 30,
  })  : _candidateDao = candidateDao ?? termCandidateDao,
        _occurrenceDao = occurrenceDao ?? termCandidateOccurrenceDao,
        _batchSize = batchSize,
        _minBatchSize = minBatchSize;

  final TermCandidateDao _candidateDao;
  final TermCandidateOccurrenceDao _occurrenceDao;
  int _batchSize;
  final int _minBatchSize;

  bool _cancelled = false;
  void cancel() => _cancelled = true;
  void resetCancellation() => _cancelled = false;

  Future<FilterOutcome> filterIfNeeded({
    required int bookId,
    void Function(int done, int total)? onProgress,
  }) async {
    resetCancellation();
    final pending = await _candidateDao.selectByStatus(
      bookId,
      CandidateStatus.candidate,
    );
    if (pending.isEmpty) {
      return const FilterSkipped('nothing-to-filter');
    }

    var accepted = 0;
    var rejected = 0;
    var uncertain = 0;
    var batchesRun = 0;
    var batchesFailedSoft = 0;
    onProgress?.call(0, pending.length);

    var done = 0;
    var i = 0;
    while (i < pending.length) {
      if (_cancelled) break;
      final end = (i + _batchSize).clamp(0, pending.length);
      final batch = pending.sublist(i, end);
      batchesRun++;

      _BatchResult result;
      try {
        result = await _runBatch(batch);
      } catch (e, st) {
        AnxLog.severe('Term filter batch failed: $e\n$st');
        return FilterFailed(error: e);
      }
      if (result.softFallback) batchesFailedSoft++;

      final accIds = <int>[];
      final rejIds = <int>[];
      final uncertainIds = <int>[];
      _assignStatuses(
        batch: batch,
        removeIndexes: result.removeIndexes,
        accIds: accIds,
        rejIds: rejIds,
        uncertainIds: uncertainIds,
      );

      if (accIds.isNotEmpty) {
        await _candidateDao.updateStatusBatch(
          ids: accIds,
          status: CandidateStatus.accepted,
          llmVerdict: 'term',
        );
        accepted += accIds.length;
      }
      if (rejIds.isNotEmpty) {
        await _candidateDao.updateStatusBatch(
          ids: rejIds,
          status: CandidateStatus.rejected,
          llmVerdict: 'garbage',
        );
        rejected += rejIds.length;
      }
      if (uncertainIds.isNotEmpty) {
        await _candidateDao.updateStatusBatch(
          ids: uncertainIds,
          status: CandidateStatus.uncertain,
          llmVerdict: 'uncertain',
        );
        uncertain += uncertainIds.length;
      }

      done = end;
      onProgress?.call(done, pending.length);
      i = end;
    }

    if (_cancelled) {
      return FilterFailed(error: const _CancelledException());
    }
    return FilterCompleted(
      accepted: accepted,
      rejected: rejected,
      uncertain: uncertain,
      batchesRun: batchesRun,
      batchesFailedSoft: batchesFailedSoft,
    );
  }

  Future<_BatchResult> _runBatch(List<TermCandidate> batch) async {
    final block = await _buildTermsBlock(batch);
    // First attempt.
    final raw = await _callLlm(block);
    final indexes = extractIntList(raw);
    if (indexes != null &&
        !looksTruncated(raw, expectArray: true) &&
        indexes.length < batch.length) {
      return _BatchResult(removeIndexes: indexes, softFallback: false);
    }

    // If truncated and batch is big, halve the batch and retry the halves
    // sequentially. We adapt globally because the model is likely to keep
    // truncating.
    if (looksTruncated(raw, expectArray: true) &&
        batch.length > _minBatchSize) {
      _batchSize = (_batchSize ~/ 2).clamp(_minBatchSize, _batchSize);
      AnxLog.warning(
        'Term filter: response truncated, halving batch_size to $_batchSize',
      );
      final half = batch.length ~/ 2;
      final first = await _runBatch(batch.sublist(0, half));
      final second = await _runBatch(batch.sublist(half));
      final merged = <int>[
        ...first.removeIndexes,
        ...second.removeIndexes.map((idx) => idx + half),
      ];
      return _BatchResult(
        removeIndexes: merged,
        softFallback: first.softFallback || second.softFallback,
      );
    }

    // Retry once with a stricter prompt: the same user content, plus a
    // reminder appended to the prompt.
    final retried = await _callLlm(
      '$block\n\nYour previous reply was not valid JSON. '
      'Reply ONLY with the JSON array of integer indexes to remove, no prose, '
      'no markdown.',
    );
    final indexes2 = extractIntList(retried);
    if (indexes2 != null) {
      return _BatchResult(removeIndexes: indexes2, softFallback: false);
    }

    // Soft fallback: keep everything in this batch.
    AnxLog.warning(
      'Term filter: could not parse JSON after retry, keeping batch as-is',
    );
    return _BatchResult(removeIndexes: const [], softFallback: true);
  }

  Future<String> _buildTermsBlock(List<TermCandidate> batch) async {
    final buf = StringBuffer();
    for (var i = 0; i < batch.length; i++) {
      final c = batch[i];
      String snippet = '';
      if (c.id != null) {
        final occs = await _occurrenceDao.selectByCandidateId(c.id!, limit: 1);
        if (occs.isNotEmpty) {
          final o = occs.first;
          final before = o.contextBefore.isEmpty
              ? ''
              : '${o.contextBefore.substring(o.contextBefore.length > 40 ? o.contextBefore.length - 40 : 0)} ';
          final after = o.contextAfter.isEmpty
              ? ''
              : ' ${o.contextAfter.substring(0, o.contextAfter.length > 40 ? 40 : o.contextAfter.length)}';
          snippet =
              ' — snippet "${before.trim()}[${c.sourceText}]${after.trim()}"';
        }
      }
      buf.writeln(
        '${i + 1}. "${c.sourceText}" freq=${c.frequencyTotal} '
        'ch=${c.chapterCount}$snippet',
      );
    }
    return buf.toString().trimRight();
  }

  Future<String> _callLlm(String termsBlock) async {
    // Retry with backoff for transient errors.
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (_cancelled) return '';
      try {
        final payload = generatePromptCandidateFilter(termsBlock);
        final messages = payload.buildMessages();
        return await aiGenerateOnce(
          messages,
          identifier: payload.identifier.name,
        );
      } on TimeoutException catch (e) {
        lastError = e;
      } on SocketException catch (e) {
        lastError = e;
      } catch (e) {
        final s = e.toString().toLowerCase();
        if (s.contains('429') ||
            s.contains('rate limit') ||
            s.contains('timeout') ||
            s.contains('network')) {
          lastError = e;
        } else {
          rethrow;
        }
      }
      final wait = Duration(milliseconds: 200 * (1 << attempt));
      await Future.delayed(wait);
    }
    if (lastError != null) throw lastError;
    return '';
  }

  void _assignStatuses({
    required List<TermCandidate> batch,
    required List<int> removeIndexes,
    required List<int> accIds,
    required List<int> rejIds,
    required List<int> uncertainIds,
  }) {
    final remove = removeIndexes.toSet();
    final highScoreCutoff = _topDecileScore(batch);

    // Salvage heuristic: if the model removed >70% of the batch, the highest
    // scored removals are likely false positives — bump them to "uncertain"
    // so Stage C still tries them.
    final removalRatio = remove.length / batch.length;
    final salvage = removalRatio > 0.7;

    for (var i = 0; i < batch.length; i++) {
      final id = batch[i].id;
      if (id == null) continue;
      final humanIndex = i + 1; // prompt uses 1-based indexes
      final isRemoved = remove.contains(humanIndex);
      if (!isRemoved) {
        accIds.add(id);
        continue;
      }
      if (salvage && batch[i].score >= highScoreCutoff) {
        uncertainIds.add(id);
      } else {
        rejIds.add(id);
      }
    }
  }

  double _topDecileScore(List<TermCandidate> batch) {
    if (batch.isEmpty) return 0;
    final scores = batch.map((c) => c.score).toList()..sort();
    final idx = (scores.length * 0.9).floor().clamp(0, scores.length - 1);
    return scores[idx];
  }
}

class _BatchResult {
  _BatchResult({required this.removeIndexes, required this.softFallback});
  final List<int> removeIndexes;
  final bool softFallback;
}

class _CancelledException implements Exception {
  const _CancelledException();
  @override
  String toString() => 'Term filter cancelled';
}

final termFilterService = TermFilterService();
