/// Greedy set-cover selector for Stage C mining.
///
/// Goal: pick the smallest set of chapters that collectively cover at least
/// [targetCoverage]% of the candidate pool (weighted by score). Each iteration
/// chooses the chapter that adds the most score-weighted new candidates.
///
/// Mirrors `mining_selector.py:35-122` in the legacy NovelTranslator project.
class MiningSelectionResult {
  MiningSelectionResult({
    required this.orderedChapterIds,
    required this.coverage,
    required this.coveredCandidateIds,
  });

  final List<int> orderedChapterIds;
  final double coverage;
  final Set<int> coveredCandidateIds;
}

class ChapterMeta {
  ChapterMeta({required this.id, required this.orderIndex, required this.title});
  final int id;
  final int orderIndex;
  final String title;
}

MiningSelectionResult selectMiningChapters({
  required Map<int, double> candidateScores,
  required Map<int, Set<int>> chapterCoverage,
  required Map<int, ChapterMeta> chapterMeta,
  double targetCoverage = 80.0,
  int maxChapters = 0,
}) {
  if (candidateScores.isEmpty || chapterCoverage.isEmpty) {
    return MiningSelectionResult(
      orderedChapterIds: const [],
      coverage: 0,
      coveredCandidateIds: <int>{},
    );
  }
  final totalScore = candidateScores.values.fold<double>(0, (a, b) => a + b);
  final targetScore = totalScore * (targetCoverage / 100.0);

  final remainingCandidates = candidateScores.keys.toSet();
  final picked = <int>[];
  final covered = <int>{};
  var accumulatedScore = 0.0;

  while (remainingCandidates.isNotEmpty) {
    if (accumulatedScore >= targetScore) break;
    if (maxChapters > 0 && picked.length >= maxChapters) break;

    int? bestChapter;
    var bestGain = 0.0;
    var bestNewCount = 0;

    chapterCoverage.forEach((chapterId, candidates) {
      if (picked.contains(chapterId)) return;
      var gain = 0.0;
      var newCount = 0;
      for (final candId in candidates) {
        if (!remainingCandidates.contains(candId)) continue;
        gain += candidateScores[candId] ?? 0;
        newCount++;
      }
      // Same tie-breaker shape as the Python implementation:
      //   newCount * 10 + gain * 0.5 + totalCandidates * 2
      final effective = newCount * 10 + gain * 0.5 + candidates.length * 2;
      if (effective > bestGain || bestChapter == null) {
        bestGain = effective;
        bestChapter = chapterId;
        bestNewCount = newCount;
      }
    });

    if (bestChapter == null || bestNewCount == 0) break;
    picked.add(bestChapter!);
    final covers = chapterCoverage[bestChapter] ?? const <int>{};
    for (final candId in covers) {
      if (remainingCandidates.remove(candId)) {
        covered.add(candId);
        accumulatedScore += candidateScores[candId] ?? 0;
      }
    }
  }

  // Order picked chapters by their natural order_index for predictable
  // processing.
  picked.sort((a, b) {
    final ma = chapterMeta[a]?.orderIndex ?? 0;
    final mb = chapterMeta[b]?.orderIndex ?? 0;
    return ma.compareTo(mb);
  });

  final finalCoverage =
      totalScore == 0 ? 0.0 : (accumulatedScore / totalScore) * 100.0;
  return MiningSelectionResult(
    orderedChapterIds: picked,
    coverage: finalCoverage,
    coveredCandidateIds: covered,
  );
}
