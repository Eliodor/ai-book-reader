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

  Map<String, RawCandidate> score(
    Map<String, RawCandidate> candidates,
    Map<String, List<ChapterCount>> chapterCountsByCandidate,
  ) {
    if (totalTokens == 0) return candidates;
    // Sort by current score desc, take top-K.
    final sorted = candidates.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    final n = sorted.length < topK ? sorted.length : topK;
    for (var i = 0; i < n; i++) {
      final cand = sorted[i];
      final counts = chapterCountsByCandidate[cand.normalizedSource];
      if (counts == null || counts.isEmpty || cand.frequencyTotal == 0) {
        continue;
      }
      var dp = 0.0;
      for (final cc in counts) {
        final chapterSize = chapterTokenCounts[cc.chapterId] ?? 0;
        if (chapterSize == 0) continue;
        final expected = chapterSize / totalTokens;
        final observed = cc.frequency / cand.frequencyTotal;
        dp += (observed - expected).abs();
      }
      dp /= 2.0;
      if (dp < 0) dp = 0;
      if (dp > 1) dp = 1;
      cand.score = cand.score * (1 + (1 - dp));
    }
    return candidates;
  }
}

class ChapterCount {
  ChapterCount({required this.chapterId, required this.frequency});
  final int chapterId;
  final int frequency;
}

/// Builds the `normalised → [(chapter_id, count)…]` map from occurrence lists.
Map<String, List<ChapterCount>> buildChapterCounts(
  Map<String, RawCandidate> candidates,
) {
  final map = <String, List<ChapterCount>>{};
  candidates.forEach((normalized, cand) {
    final byChapter = <int, int>{};
    for (final occ in cand.occurrences) {
      byChapter[occ.chapterId] = (byChapter[occ.chapterId] ?? 0) + 1;
    }
    // Occurrences are capped at `maxOccurrencesPerCandidate`. For dispersion
    // we need the chapter set + estimated within-chapter count. chapterIds is
    // authoritative for "in which chapter"; for the count we fall back to
    // `frequencyTotal / chapterIds.length` once the occurrence cap is hit.
    if (cand.occurrences.length == cand.frequencyTotal) {
      map[normalized] = byChapter.entries
          .map((e) => ChapterCount(chapterId: e.key, frequency: e.value))
          .toList(growable: false);
    } else {
      final perChapter =
          cand.chapterIds.isEmpty ? 0 : cand.frequencyTotal ~/ cand.chapterIds.length;
      map[normalized] = cand.chapterIds
          .map((id) => ChapterCount(
                chapterId: id,
                frequency: perChapter == 0 ? 1 : perChapter,
              ))
          .toList(growable: false);
    }
  });
  return map;
}
