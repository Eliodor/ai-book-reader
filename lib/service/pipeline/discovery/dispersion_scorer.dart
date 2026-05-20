import 'package:ai_book_reader/service/pipeline/discovery/raw_models.dart';

/// Stage 3 — Gries DP dispersion boost for the top-K candidates from Stage 2.
///
/// `DP = ½ · Σ |y_i/AF − n_i/N|` where `y_i` is the candidate's frequency in
/// chapter `i`, `AF` is its book-wide frequency, `n_i` is the chapter size,
/// `N` is the corpus size. DP=0 → ideal even spread, DP=1 → all in one chunk.
///
/// We boost the final score by `(1 + (1 − DP))` so terms that recur across the
/// whole book get up to a 2× lift while episodic mentions are not penalised
/// — their boost just stays near 1×.
///
/// Reads per-chapter frequencies directly from [RawCandidate.chapterFrequencies]
/// which is maintained exactly by [CandidateGenerator] and the morphology
/// merge, so DP works for high-frequency terms (the ones we care about).
class DispersionScorer {
  DispersionScorer({
    required this.chapterTokenCounts,
    required this.totalTokens,
    required this.earlyChapterIds,
  });

  /// `chapterId` → token count in that chapter.
  final Map<int, int> chapterTokenCounts;
  final int totalTokens;

  /// IDs of the chapters that fall in the first ~third of the book. A term
  /// first introduced inside this window and recurring later is almost
  /// always a core plot element (main character, location, ability),
  /// regardless of language.
  final Set<int> earlyChapterIds;

  Map<String, RawCandidate> score(Map<String, RawCandidate> candidates) {
    if (totalTokens == 0) return candidates;
    // Dispersion now runs on every candidate, not just the top-K. Evenly
    // spread terms that sit deep in the list get the same up-to-2× boost
    // as the head — that's where most of the wiki-recall on the long tail
    // came from in the analysis.
    for (final cand in candidates.values) {
      if (cand.chapterFrequencies.isEmpty || cand.frequencyTotal == 0) {
        continue;
      }
      var dp = 0.0;
      cand.chapterFrequencies.forEach((chapterId, freq) {
        final chapterSize = chapterTokenCounts[chapterId] ?? 0;
        if (chapterSize == 0) return;
        final expected = chapterSize / totalTokens;
        final observed = freq / cand.frequencyTotal;
        dp += (observed - expected).abs();
      });
      dp /= 2.0;
      if (dp < 0) dp = 0;
      if (dp > 1) dp = 1;
      var multiplier = 1 + (1 - dp);

      final firstChId = cand.firstChapterId;
      final earlyAppearance =
          firstChId != null && earlyChapterIds.contains(firstChId);
      if (earlyAppearance && cand.frequencyTotal >= 5) {
        multiplier *= 1.2;
      }

      cand.score = cand.score * multiplier;
    }
    return candidates;
  }
}
