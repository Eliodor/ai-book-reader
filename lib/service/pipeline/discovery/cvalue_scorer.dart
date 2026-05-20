import 'dart:math' as math;

import 'package:ai_book_reader/service/pipeline/discovery/raw_models.dart';

/// Stage 2: applies the C-value formula (Frantzi/Ananiadou/Mima 2000) to each
/// multi-word candidate and multiplies it by two truncated YAKE features —
/// T_Case (uppercase boost) and T_DifSentence (sentence dispersion).
///
/// We deliberately skip T_Position and T_Rel from YAKE (their ROI in book
/// material is low and they are expensive to compute).
class CValueScorer {
  CValueScorer({required this.totalSentences});

  /// Total sentence count across the corpus — used by T_DifSentence.
  final int totalSentences;

  /// Outer-loop iteration count between cancellation checks. A typical book
  /// pushes ~thousands of candidates through this scorer, so a check every
  /// 1000 outer rows keeps responsiveness within a few hundred ms.
  static const int _cancelCheckInterval = 1000;

  /// Score every candidate in [candidates] in place. Returns the same map.
  ///
  /// Async so the worker isolate can yield to its event loop periodically and
  /// observe a cancellation signal mid-scan. Cancellation is checked every
  /// [_cancelCheckInterval] outer iterations.
  Future<Map<String, RawCandidate>> score(
    Map<String, RawCandidate> candidates, {
    bool Function()? isCancelled,
  }) async {
    // 1. Build inverted index: for every candidate, find longer candidates
    //    that contain it as a sub-phrase. Single-word candidates can be
    //    contained in any longer one; multi-word in any strictly longer one.
    //
    //    The inner loop matches `' inner '` against `' outer '` to enforce
    //    word boundaries. We pre-compute both padded forms once per candidate
    //    so the hot loop doesn't allocate a new wrapper string per probe.
    final byWordCount = <int, List<RawCandidate>>{};
    final padded = <String, String>{};
    for (final c in candidates.values) {
      byWordCount.putIfAbsent(c.wordCount, () => []).add(c);
      padded[c.normalizedSource] = ' ${c.normalizedSource} ';
    }
    final maxLen =
        byWordCount.keys.isEmpty ? 0 : byWordCount.keys.reduce(math.max);

    var counter = 0;
    for (final cand in candidates.values) {
      if (cand.wordCount >= maxLen) continue;
      final candWords = padded[cand.normalizedSource]!;
      for (var len = cand.wordCount + 1; len <= maxLen; len++) {
        final longer = byWordCount[len];
        if (longer == null) continue;
        for (final lc in longer) {
          if (padded[lc.normalizedSource]!.contains(candWords)) {
            if (cand.superCandidateKeys.add(lc.normalizedSource)) {
              cand.nestedFrequency += lc.frequencyTotal;
            }
          }
        }
      }
      counter++;
      if (counter % _cancelCheckInterval == 0) {
        await Future<void>.delayed(Duration.zero);
        if (isCancelled?.call() ?? false) return candidates;
      }
    }

    // 2. Apply C-value, T_Case, T_DifSentence, type bonus.
    for (final cand in candidates.values) {
      final logLen = math.log(math.max(2, cand.wordCount)) / math.ln2;
      double cValue;
      if (cand.superCandidateKeys.isEmpty) {
        cValue = logLen * cand.frequencyTotal.toDouble();
      } else {
        final n = cand.superCandidateKeys.length;
        final avgNested = cand.nestedFrequency / n;
        cValue = logLen * (cand.frequencyTotal - avgNested);
        if (cValue < 0) cValue = 0;
      }

      // Casing bonus: log-scaled ratio of ALL-CAPS occurrences.
      final caseRatio = cand.frequencyTotal == 0
          ? 0.0
          : cand.allCapsOccurrences / cand.frequencyTotal;
      final tCase = 1 + math.log(1 + caseRatio);

      // Sentence dispersion: how diverse are the contexts.
      final difSentence = totalSentences == 0
          ? 1.0
          : math.log(2 + cand.uniqueSentences.length / totalSentences);

      // Type bonus: proper_name / title / organization candidates are
      // structurally more likely to be glossary terms than free phrases. The
      // type was already inferred from capitalisation in CandidateGenerator,
      // so this re-uses an existing signal with no extra cost.
      final typeBoost = _typeBoostsByType[cand.candidateType] ?? 1.0;

      cand.score = cValue * tCase * difSentence * typeBoost;
      if (cand.score < 0) cand.score = 0;
    }

    return candidates;
  }

  static const Map<String, double> _typeBoostsByType = {
    'proper_name': 1.4,
    'title': 1.3,
    'organization': 1.3,
    'technique': 1.2,
  };
}
