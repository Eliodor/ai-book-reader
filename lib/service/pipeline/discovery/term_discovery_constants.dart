/// Compile-time constants used by Stage A term discovery — connectors that may
/// glue adjacent capitalised tokens into a single multi-word candidate
/// ("Master of the Crimson Hall"), regex sources, and default knobs.
///
/// Anything that depends on the source language stays in
/// [connectorsByLanguage]; everything else is language-neutral.
library;

import 'dart:math' as math;

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

/// Default number of top candidates persisted per book after Stage A.
///
/// Acts as the anchor for [adaptiveDiscoveryTopN] — a book of ~100 chapters
/// (the size that produced the original benchmark on Solo Leveling) gets
/// exactly this many candidates. Smaller and larger books are scaled
/// sublinearly around this point.
///
/// The anchor is set above the typical score>0 pool size (~2 250 on
/// Solo Leveling) so that the `minScore` floor stays the primary cutoff and
/// `topN` is a safety net.
const int defaultDiscoveryTopN = 3000;

/// Lower / upper bounds for [adaptiveDiscoveryTopN].
/// - 500 floor: even a novella keeps enough candidates to make Stage B's
///   batching worthwhile (~5 LLM calls).
/// - 30000 ceiling: `topN` is now a safety net rather than the primary
///   cutoff. The score-based floor (`DiscoveryInput.minScore = 0.0` in the
///   isolate) is what shapes the real pool size — anything with `score > 0`
///   passes. Raising the ceiling lets long web-novels (2 500+ chapters in
///   Chinese / Korean / Japanese) keep their full positive-score pool
///   instead of being arbitrarily truncated at 5 000. C-value time stays
///   bounded by the heuristic junk filter that runs *before* C-value.
const int minAdaptiveTopN = 500;
const int maxAdaptiveTopN = 30000;

/// Returns the top-N target for a book with [chapterCount] chapters.
///
/// Why sqrt — vocabulary in a corpus grows as O(N^β) with β ≈ 0.5
/// (Heaps' law), so the useful proper-noun pool is sublinear in book
/// size. Linear scaling like "5 terms/chapter" would give 50 terms for a
/// novella (too few) and 15000 for a 3000-chapter web serial (too many).
///
/// Examples:
///   chapters=10    → 949
///   chapters=50    → 2121
///   chapters=100   → 3000   (anchor, equal to defaultDiscoveryTopN)
///   chapters=200   → 4243
///   chapters=500   → 6708
///   chapters=1000  → 9487
///   chapters=2600  → 15297
///   chapters=4000  → 18974
///   chapters=10000 → 30000  (ceiling)
int adaptiveDiscoveryTopN(int chapterCount) {
  if (chapterCount <= 0) return defaultDiscoveryTopN;
  final raw =
      (defaultDiscoveryTopN * math.sqrt(chapterCount / 100)).round();
  return raw.clamp(minAdaptiveTopN, maxAdaptiveTopN);
}

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

/// Heuristic junk pre-filter — applied at the very end of Stage A, before
/// persistence. Drops candidates that are almost certainly noise so Stage B
/// doesn't pay LLM money for them. See `term_discovery_isolate.dart` /
/// `_heuristicJunkFilter`.
///
/// For a **single-word** candidate, `<= heuristicJunkSingleChapterMaxFreq`
/// AND `chapter_count == 1` means it's a fleeting mention. A real single-word
/// proper noun recurs across the book; a singleton burst in one chapter is
/// usually onomatopoeia, an ALL-CAPS false positive (`Hp Hp`, `Atm`, `Sos`),
/// or a sentence-initial common noun that just happened to slip the trust
/// check (`Friendship`, `Boss`).
///
/// Multi-word fleeting candidates do **not** apply this rule — multi-word
/// rare candidates are more likely to be real proper nouns like
/// `Dungeon Jackals` or `Penalty Zone`.
const int heuristicJunkSingleChapterMaxFreq = 2;

/// `>= heuristicJunkLongPhraseWordCount` total words — dialogue / System
/// sentence. Glossary canonicals in narrative text are 1-4 words; anything
/// 5+ comes from quoted-span dialogue or `[…]` System messages that slipped
/// through the chain assembler.
const int heuristicJunkLongPhraseWordCount = 5;
