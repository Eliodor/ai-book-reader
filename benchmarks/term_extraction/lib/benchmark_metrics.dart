import 'package:term_extraction_benchmark/term_matcher.dart';

/// Stopwords used by loose match to prevent things like "the" / "is" from
/// covering ground-truth terms via substring. Small English-only list — the
/// pipeline runs on English text for the Solo Leveling benchmark.
const Set<String> defaultStopwords = {
  'a', 'an', 'the', 'and', 'or', 'but', 'of', 'in', 'on', 'at', 'to', 'for',
  'with', 'by', 'from', 'as', 'is', 'was', 'are', 'were', 'be', 'been', 'being',
  'this', 'that', 'these', 'those', 'it', 'its', 'has', 'have', 'had', 'do',
  'does', 'did', 'he', 'she', 'they', 'them', 'his', 'her', 'their', 'i', 'me',
  'my', 'we', 'us', 'our', 'you', 'your', 'not', 'no', 'all', 'some', 'any',
  'one', 'two', 'three', 'four', 'five', 'who', 'what', 'where', 'when', 'why',
  'how', 'will', 'would', 'can', 'could', 'should', 'may', 'might',
};

/// One ground-truth entry being checked. Identical shape regardless of source
/// category — kept so the metrics loop is uniform.
class GtTerm {
  GtTerm({
    required this.category,
    required this.canonical,
    required this.isEpithet,
  });

  final String category;
  final String canonical;
  final bool isEpithet;

  late final String normalized = normalizeForMatch(canonical);
}

/// What the pipeline produced. Loaded from `tb_term_candidates`.
class Candidate {
  Candidate({
    required this.id,
    required this.sourceText,
    required this.normalizedSource,
    required this.candidateType,
    required this.score,
    required this.frequencyTotal,
    required this.chapterCount,
    required this.status,
  });

  final int id;
  final String sourceText;
  final String normalizedSource;
  final String candidateType;
  final double score;
  final int frequencyTotal;
  final int chapterCount;
  final String status;

  /// `normalize`d form ready for matching — built once per row.
  late final String normalizedForMatch = normalizeForMatch(sourceText);
}

enum MatchMode { strict, loose }

class MatchOutcome {
  MatchOutcome({required this.found, this.candidateId, this.candidateText});

  final bool found;
  final int? candidateId;
  final String? candidateText;
}

/// Does any candidate in [candidates] match [term] under [mode]?
/// For [MatchMode.loose] we accept any whole-word substring of length ≥ 4
/// that is not a stopword. This is what catches "Jinwoo" covering
/// "Sung Jinwoo" when the wiki canonical is the full name but the book
/// mostly uses the short form.
MatchOutcome matchTerm(
  GtTerm term,
  List<Candidate> candidates, {
  required MatchMode mode,
  Set<String>? stopwords,
}) {
  final stops = stopwords ?? defaultStopwords;
  for (final c in candidates) {
    if (c.normalizedForMatch == term.normalized) {
      return MatchOutcome(
        found: true,
        candidateId: c.id,
        candidateText: c.sourceText,
      );
    }
  }
  if (mode == MatchMode.strict) return MatchOutcome(found: false);
  // Bidirectional whole-word substring:
  //   (a) candidate is contained in gt term  → "Jinwoo" covers "Sung Jinwoo"
  //   (b) gt term  is contained in candidate → "Detection" covered by
  //                                            "Skill Eyes Of Detection"
  // Both sides need length ≥ 4 and non-stopword on the *short* side, to
  // avoid trivial covers like "the".
  final termNorm = term.normalized;
  if (termNorm.length >= 4 && !stops.contains(termNorm)) {
    for (final c in candidates) {
      final cn = c.normalizedForMatch;
      if (cn.length <= termNorm.length) continue;
      if (_isWholeWordSubstring(termNorm, cn)) {
        return MatchOutcome(
          found: true,
          candidateId: c.id,
          candidateText: c.sourceText,
        );
      }
    }
  }
  for (final c in candidates) {
    final cn = c.normalizedForMatch;
    if (cn.length < 4) continue;
    if (stops.contains(cn)) continue;
    if (_isWholeWordSubstring(cn, termNorm)) {
      return MatchOutcome(
        found: true,
        candidateId: c.id,
        candidateText: c.sourceText,
      );
    }
  }
  return MatchOutcome(found: false);
}

bool _isWholeWordSubstring(String needle, String haystack) {
  final n = haystack.length;
  final m = needle.length;
  if (m >= n) return false;
  var from = 0;
  while (true) {
    final idx = haystack.indexOf(needle, from);
    if (idx < 0) return false;
    final before = idx == 0 ? null : haystack.codeUnitAt(idx - 1);
    final afterIdx = idx + m;
    final after = afterIdx >= n ? null : haystack.codeUnitAt(afterIdx);
    if (!_isWordChar(before) && !_isWordChar(after)) return true;
    from = idx + 1;
  }
}

bool _isWordChar(int? codeUnit) {
  if (codeUnit == null) return false;
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return true;
  if (codeUnit >= 0x41 && codeUnit <= 0x5A) return true;
  if (codeUnit >= 0x61 && codeUnit <= 0x7A) return true;
  if (codeUnit == 0x5F) return true;
  if (codeUnit > 0x7F) return true;
  return false;
}

class CategoryRecall {
  CategoryRecall({required this.category, required this.terms});
  final String category;
  final int terms;
  int foundStrict = 0;
  int foundLoose = 0;

  double get recallStrict => terms == 0 ? 0 : foundStrict / terms;
  double get recallLoose => terms == 0 ? 0 : foundLoose / terms;
}

/// Compute recall over [gtTerms] using [candidates] for both strict and
/// loose match modes. Returns one row per ground-truth category, plus an
/// aggregate "TOTAL" row.
List<CategoryRecall> computeRecallByCategory(
  List<GtTerm> gtTerms,
  List<Candidate> candidates,
) {
  final perCategory = <String, CategoryRecall>{};
  for (final t in gtTerms) {
    perCategory.putIfAbsent(
      t.category,
      () => CategoryRecall(category: t.category, terms: 0),
    );
  }
  // Recompute "terms" — we lazily added above with 0.
  for (final entry in perCategory.entries) {
    final cat = entry.key;
    final count = gtTerms.where((t) => t.category == cat).length;
    perCategory[cat] = CategoryRecall(category: cat, terms: count);
  }
  for (final t in gtTerms) {
    final strict = matchTerm(t, candidates, mode: MatchMode.strict);
    final loose = matchTerm(t, candidates, mode: MatchMode.loose);
    final row = perCategory[t.category]!;
    if (strict.found) row.foundStrict++;
    if (loose.found) row.foundLoose++;
  }
  final rows = perCategory.values.toList()
    ..sort((a, b) => a.category.compareTo(b.category));
  final total = CategoryRecall(
    category: 'TOTAL',
    terms: gtTerms.length,
  );
  for (final r in rows) {
    total.foundStrict += r.foundStrict;
    total.foundLoose += r.foundLoose;
  }
  rows.add(total);
  return rows;
}
