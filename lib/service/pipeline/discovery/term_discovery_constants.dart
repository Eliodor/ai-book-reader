/// Compile-time constants used by Stage A term discovery — connectors that may
/// glue adjacent capitalised tokens into a single multi-word candidate
/// ("Master of the Crimson Hall"), regex sources, and default knobs.
///
/// Anything that depends on the source language stays in
/// [connectorsByLanguage]; everything else is language-neutral.
library;

/// Soft connectors per language. They are accepted between two capitalised
/// tokens during candidate generation but never start or end a candidate.
const Map<String, List<String>> connectorsByLanguage = {
  'en': ['of', 'the', 'and', 'de', 'la', 'du'],
  'ru': ['из', 'на', 'в', 'и', 'у', 'с', 'от', 'по', 'до'],
  'uk': ['з', 'на', 'в', 'і', 'у', 'до', 'по', 'від'],
  'de': ['von', 'der', 'die', 'das', 'des', 'dem', 'den', 'zu', 'zum', 'zur',
        'und', 'aus'],
  'fr': ['de', 'du', 'des', 'la', 'le', 'les', "l'", 'et', 'au', 'aux'],
  'es': ['de', 'del', 'la', 'las', 'el', 'los', 'y'],
  'it': ['di', 'del', 'della', 'delle', 'dei', 'da', 'e', 'lo', 'la', 'il'],
  'pt': ['de', 'do', 'da', 'dos', 'das', 'e'],
  'pl': ['z', 'i', 'do', 'od', 'w', 'na'],
  'nl': ['van', 'de', 'het', 'en', 'uit'],
};

/// Words that are case-insensitively excluded from being the first or last
/// significant token of a multi-word candidate (so we don't produce "The Hall"
/// as a candidate). Language fallbacks come from stopwords-iso; this is only
/// for safety when stopword loading fails or a language is missing.
const Set<String> universalArticles = {
  'a', 'an', 'the', 'and', 'or', 'of', 'in', 'on', 'at', 'to',
};

/// Default number of top candidates persisted per book after Stage A. Higher
/// than the Python value to keep recall up for Stage B.
const int defaultDiscoveryTopN = 1500;

/// Maximum number of words in a multi-word candidate.
const int maxCandidateWordCount = 6;

/// Frequency floors for the cheap n-gram extractor in Stage 1 (used mainly for
/// non-Latin scripts where capitalisation isn't a signal).
const int ngramMinFrequency = 5;
const int ngramMinChapterCount = 2;

/// All-caps detection requires this many additional occurrences in the book to
/// avoid noise like onomatopoeia and angry dialogue ("NO!").
const int allCapsMinFrequency = 2;

/// Stage 3 (Gries DP) only runs over the top-K candidates by Stage 2 score.
const int dispersionTopK = 5000;

/// Stage 4 single-pass clustering similarity threshold for the char-trigram
/// Jaccard fallback (Snowball-supported languages use stem-tuple identity).
const double clusterJaccardThreshold = 0.85;

/// Stage 5 substring containment soft penalty multiplier when the shorter form
/// is mostly nested inside a longer one.
const double substringNestedPenalty = 0.5;
const double substringNestedRatio = 0.8;

/// Maximum number of occurrences persisted per candidate (we only need a
/// couple of snippets for the LLM filter).
const int maxOccurrencesPerCandidate = 2;

/// Context snippet length on each side of a candidate occurrence.
const int occurrenceContextHalfWidth = 60;
