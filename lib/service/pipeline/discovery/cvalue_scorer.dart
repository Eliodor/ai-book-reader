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

  /// Score every candidate in [candidates] in place. Returns the same map.
  Map<String, RawCandidate> score(Map<String, RawCandidate> candidates) {
    final byNormalized = <String, RawCandidate>{};
    candidates.forEach((k, v) => byNormalized[k] = v);

    // 1. Build inverted index: for every candidate, find longer candidates
    //    that contain it as a sub-phrase. Single-word candidates can be
    //    contained in any longer one; multi-word in any strictly longer one.
    final byWordCount = <int, List<RawCandidate>>{};
    for (final c in byNormalized.values) {
      byWordCount.putIfAbsent(c.wordCount, () => []).add(c);
    }
    final maxLen =
        byWordCount.keys.isEmpty ? 0 : byWordCount.keys.reduce(math.max);

    for (final cand in byNormalized.values) {
      if (cand.wordCount >= maxLen) continue;
      final candWords = ' ${cand.normalizedSource} ';
      for (var len = cand.wordCount + 1; len <= maxLen; len++) {
        final longer = byWordCount[len];
        if (longer == null) continue;
        for (final lc in longer) {
          if ((' ${lc.normalizedSource} ').contains(candWords)) {
            cand.superCandidateIndices.add(lc.hashCode);
            cand.nestedFrequency += lc.frequencyTotal;
          }
        }
      }
    }

    // 2. Apply C-value, T_Case, T_DifSentence.
    for (final cand in byNormalized.values) {
      final logLen = math.log(math.max(2, cand.wordCount)) / math.ln2;
      double cValue;
      if (cand.superCandidateIndices.isEmpty) {
        cValue = logLen * cand.frequencyTotal.toDouble();
      } else {
        final n = cand.superCandidateIndices.length;
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

      cand.score = cValue * tCase * difSentence;
      if (cand.score < 0) cand.score = 0;
    }

    return byNormalized;
  }
}
