import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Normalizes a string for term matching: NFC composition + lowercase.
/// Both the corpus text and every term must go through this before any
/// comparison so accent / case variation doesn't cause spurious mismatches.
///
/// Use this when comparing two algorithm-produced strings to each other
/// (e.g. a Stage A candidate vs a ground-truth canonical) — the algorithm
/// promotes whatever capitalisation the text used, so we normalise both
/// sides.
String normalizeForMatch(String s) => unorm.nfc(s).toLowerCase();

/// Case-preserving NFC normalisation. Use this for `present-in-text`
/// checks where we want to distinguish "Red Gate" (proper noun usage)
/// from "red gate" (descriptive prose) — only the former is something
/// Stage A can pick up as a candidate.
String normalizeKeepCase(String s) => unorm.nfc(s);

/// Whole-word match aware of Unicode letters. We avoid `RegExp.allMatches` per
/// term — at ~700 terms × ~4 MB text it spends most of the time in the regex
/// engine. Plain `String.indexOf` with manual boundary checks is ~50× faster
/// on real corpora.
class TermMatcher {
  TermMatcher(String normalizedText) : _text = normalizedText;

  final String _text;

  /// Count whole-word occurrences of [normalizedTerm] in the corpus.
  int count(String normalizedTerm) {
    if (normalizedTerm.isEmpty) return 0;
    final text = _text;
    final n = text.length;
    final m = normalizedTerm.length;
    if (m > n) return 0;
    var hits = 0;
    var from = 0;
    while (true) {
      final idx = text.indexOf(normalizedTerm, from);
      if (idx < 0) break;
      final before = idx == 0 ? null : text.codeUnitAt(idx - 1);
      final afterIdx = idx + m;
      final after = afterIdx >= n ? null : text.codeUnitAt(afterIdx);
      if (!_isWordChar(before) && !_isWordChar(after)) {
        hits++;
      }
      from = idx + 1;
    }
    return hits;
  }

  /// Convenience: presence with a minimum count threshold.
  bool present(String normalizedTerm, {int minCount = 1}) =>
      count(normalizedTerm) >= minCount;

  /// Considers a code unit a "word char" if it is an ASCII letter or digit,
  /// the underscore, or any codepoint above ASCII (covers all Unicode letters
  /// without table lookups — good enough for boundary detection on prose).
  ///
  /// Visible to siblings in this library (e.g. `CaseSensitiveTermMatcher`).
  static bool isWordChar(int? codeUnit) => _isWordChar(codeUnit);

  static bool _isWordChar(int? codeUnit) {
    if (codeUnit == null) return false;
    if (codeUnit >= 0x30 && codeUnit <= 0x39) return true; // 0-9
    if (codeUnit >= 0x41 && codeUnit <= 0x5A) return true; // A-Z
    if (codeUnit >= 0x61 && codeUnit <= 0x7A) return true; // a-z
    if (codeUnit == 0x5F) return true; // _
    if (codeUnit > 0x7F) return true; // any non-ASCII → treat as letter
    return false;
  }
}

/// Smart matcher used by `filter_by_text` to decide whether a wiki
/// canonical is "really" in the book in a way Stage A could pick up.
///
/// Two ideas combined:
///
/// 1. **Punctuation-tolerant**: hyphens, apostrophes, periods are stripped
///    from both the corpus and the term before search. So a wiki canonical
///    `Sung Jinwoo` matches the Yen Press text `Sung Jin-Woo` (both become
///    `Sung Jinwoo` / `SungJinWoo` after strip+search). Spaces are kept.
///
/// 2. **Capitalisation gate**: a match counts only if *at least one*
///    occurrence in the text starts with an uppercase letter. So
///    `Goblins` in the wiki maps to `goblins` in the book (lots of
///    occurrences, never capitalised) → 0. But `Sung Jinwoo` mapping to
///    `Sung Jin-Woo` (always capitalised) → kept with the full count.
///
/// This excludes generic plurals / common nouns (Stage A's capitalisation
/// rule wouldn't promote those) while keeping proper-noun spellings even
/// when the wiki and the book differ on hyphenation.
class CaseSensitiveTermMatcher {
  CaseSensitiveTermMatcher(String text)
      : _textCase = _stripPunct(normalizeKeepCase(text)),
        _textLower = _stripPunct(normalizeForMatch(text));

  final String _textCase; // case preserved, punctuation stripped
  final String _textLower; // lowercase, punctuation stripped — same length

  int count(String term) {
    if (term.isEmpty) return 0;
    final stripped = _stripPunct(normalizeKeepCase(term));
    if (stripped.isEmpty) return 0;
    final needleLower = stripped.toLowerCase();
    final n = _textLower.length;
    final m = needleLower.length;
    if (m > n) return 0;

    var hits = 0;
    var anyCapitalised = false;
    var from = 0;
    while (true) {
      final idx = _textLower.indexOf(needleLower, from);
      if (idx < 0) break;
      final before = idx == 0 ? null : _textLower.codeUnitAt(idx - 1);
      final afterIdx = idx + m;
      final after = afterIdx >= n ? null : _textLower.codeUnitAt(afterIdx);
      if (!TermMatcher.isWordChar(before) &&
          !TermMatcher.isWordChar(after)) {
        hits++;
        if (!anyCapitalised) {
          final first = _textCase.codeUnitAt(idx);
          if (first >= 0x41 && first <= 0x5A) anyCapitalised = true;
        }
      }
      from = idx + 1;
    }
    return anyCapitalised ? hits : 0;
  }

  /// Strip punctuation that frequently varies between wiki and book
  /// canonicals: ASCII apostrophe, Unicode curly apostrophes, hyphens,
  /// periods, commas. Spaces are kept (multi-word boundary is meaningful).
  static String _stripPunct(String s) =>
      s.replaceAll(RegExp(r"[-'‘’ʼ\.,]"), '');
}
