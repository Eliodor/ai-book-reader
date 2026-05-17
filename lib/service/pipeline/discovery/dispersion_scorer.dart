import 'package:ai_book_reader/service/pipeline/discovery/raw_models.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_constants.dart';

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
    int? topK,
  }) : topK = topK ?? dispersionTopK;

  /// `chapterId` → token count in that chapter.
  final Map<int, int> chapterTokenCounts;
  final int totalTokens;
  final int topK;

  Map<String, RawCandidate> score(Map<String, RawCandidate> candidates) {
    if (totalTokens == 0) return candidates;
    final sorted = candidates.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    final n = sorted.length < topK ? sorted.length : topK;
    for (var i = 0; i < n; i++) {
      final cand = sorted[i];
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
      cand.score = cand.score * (1 + (1 - dp));
    }
    return candidates;
  }
}
