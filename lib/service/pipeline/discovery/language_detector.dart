/// Detects the source language of a book by measuring how many of the first
/// N tokens fall into each language's stopword set. Whichever language wins
/// is returned; if no language scores above [minScoreRatio], we fall back to
/// `'en'` with a sentinel so the caller can surface a warning.
///
/// Pure function — caller pre-loads all stopword sets via [StopwordsLoader].
class LanguageDetectionResult {
  LanguageDetectionResult({
    required this.languageCode,
    required this.confidence,
    required this.isFallback,
  });

  final String languageCode;
  final double confidence;
  final bool isFallback;
}

LanguageDetectionResult detectLanguage({
  required List<String> sampleTokens,
  required Map<String, Set<String>> stopwordsByLang,
  double minScoreRatio = 0.01,
}) {
  if (sampleTokens.isEmpty || stopwordsByLang.isEmpty) {
    return LanguageDetectionResult(
      languageCode: 'en',
      confidence: 0,
      isFallback: true,
    );
  }

  final total = sampleTokens.length;
  var bestLang = 'en';
  var bestScore = 0;
  for (final entry in stopwordsByLang.entries) {
    var hits = 0;
    final set = entry.value;
    for (final token in sampleTokens) {
      if (set.contains(token)) hits++;
    }
    if (hits > bestScore) {
      bestScore = hits;
      bestLang = entry.key;
    }
  }

  final ratio = bestScore / total;
  if (ratio < minScoreRatio) {
    return LanguageDetectionResult(
      languageCode: 'en',
      confidence: ratio,
      isFallback: true,
    );
  }
  return LanguageDetectionResult(
    languageCode: bestLang,
    confidence: ratio,
    isFallback: false,
  );
}
