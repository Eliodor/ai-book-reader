import 'package:ai_book_reader/service/pipeline/discovery/raw_models.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_constants.dart';

/// Stage 5 — Soft substring containment penalty.
///
/// For every pair `(a, b)` where `a` is a sub-phrase of `b`, if `a` appears
/// inside `b` more than [substringNestedRatio] of the time, multiply `a`'s
/// score by [substringNestedPenalty]. We never delete — Stage B is the LLM
/// gate, here we just dampen near-duplicates that are mostly absorbed.
void applySubstringPenalty(Map<String, RawCandidate> candidates) {
  if (candidates.length < 2) return;

  // Group by word count to keep substring lookups cheap.
  final byWordCount = <int, List<RawCandidate>>{};
  for (final c in candidates.values) {
    byWordCount.putIfAbsent(c.wordCount, () => []).add(c);
  }
  final lengths = byWordCount.keys.toList()..sort();
  if (lengths.length < 2) return;

  for (var i = 0; i < lengths.length - 1; i++) {
    final shorter = byWordCount[lengths[i]] ?? [];
    if (shorter.isEmpty) continue;
    for (final s in shorter) {
      if (s.frequencyTotal == 0) continue;
      // Find a longer candidate containing this one — reuse the nested
      // frequency we already accumulated in Stage 2.
      if (s.nestedFrequency == 0) continue;
      final ratio = s.nestedFrequency / s.frequencyTotal;
      if (ratio >= substringNestedRatio) {
        s.score = s.score * substringNestedPenalty;
      }
    }
  }
}
