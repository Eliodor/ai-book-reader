import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// One token plus the metadata Stage A needs:
/// - `start` / `end` — character offsets in the source content.
/// - `sentenceIndex` — 0-based sentence sequence inside the chapter.
/// - `isCapitalized` — `\p{Lu}\p{Ll}+` OR `\p{Lu}{2,}` (Title Case or ALL CAPS).
/// - `isAllCaps` — only ALL CAPS multi-letter (≥2 chars).
/// - `isSentenceInitial` — first non-punctuation token of its sentence.
class Token {
  Token({
    required this.text,
    required this.normalizedText,
    required this.start,
    required this.end,
    required this.sentenceIndex,
    required this.isCapitalized,
    required this.isAllCaps,
    required this.isSentenceInitial,
  });

  final String text;
  final String normalizedText; // NFC + lower-case
  final int start;
  final int end;
  final int sentenceIndex;
  final bool isCapitalized;
  final bool isAllCaps;
  final bool isSentenceInitial;
}

/// Result of tokenising a chapter.
class TokenizedChapter {
  TokenizedChapter({
    required this.chapterId,
    required this.orderIndex,
    required this.tokens,
    required this.sentenceCount,
    required this.normalizedContent,
  });

  final int chapterId;
  final int orderIndex;
  final List<Token> tokens;
  final int sentenceCount;

  /// NFC-normalised content used for context snippets.
  final String normalizedContent;
}

final RegExp _wordOrSentenceBoundary = RegExp(
  // Match either a "word-ish" run (letters + connecting marks + apostrophes +
  // internal hyphens) OR a sentence terminator. \p{L} covers Latin, Cyrillic,
  // Arabic, Hebrew, plus the CJK block. Dart's RegExp doesn't accept Script=Han
  // properties; for CJK we fall back to the in-text n-gram channel anyway.
  r"(?:[\p{L}\p{M}\p{Nd}]+(?:['’\-][\p{L}\p{M}\p{Nd}]+)*|[\.\?!]+)",
  unicode: true,
);

final RegExp _allCapsPattern =
    RegExp(r'^\p{Lu}{2,}$', unicode: true, caseSensitive: true);
final RegExp _titleCasePattern =
    RegExp(r'^\p{Lu}\p{Ll}+$', unicode: true, caseSensitive: true);

/// Trailing English possessive `'s` / curly `’s` / modifier `ʼs`. Stripped
/// from `normalizedText` so that `Kamish's Wrath` and `Kamish Wrath` collapse
/// to the same internal key. `text` keeps the original apostrophe for
/// display. False positives for contractions (`it's`) are harmless — the
/// unstripped stem is a stopword and gets boundary-filtered anyway.
///
/// `\u` escapes are used instead of literal apostrophes because the Dart
/// RegExp engine has been observed to silently miss U+2019 / U+02BC inside
/// raw-string character classes on Windows.
final RegExp _trailingPossessive =
    RegExp("['’ʼ]s\$");

/// Tokenise [content] into [Token]s with sentence boundaries.
///
/// Pure function — safe to call inside an Isolate. The Isolate doesn't ship
/// `unorm_dart` natively, but the package is pure Dart so it works there too.
TokenizedChapter tokenize({
  required int chapterId,
  required int orderIndex,
  required String content,
}) {
  // Normalise the input so equivalent characters (ӗ vs ё, NFD vs NFC) collapse.
  final normalized = unorm.nfc(content);
  final tokens = <Token>[];
  var sentenceIndex = 0;
  var sentenceJustStarted = true;

  for (final match in _wordOrSentenceBoundary.allMatches(normalized)) {
    final text = match.group(0)!;
    if (_isSentenceTerminator(text)) {
      sentenceIndex++;
      sentenceJustStarted = true;
      continue;
    }
    final isAllCaps = _allCapsPattern.hasMatch(text);
    final isTitle = _titleCasePattern.hasMatch(text);
    final lower = text.toLowerCase();
    tokens.add(Token(
      text: text,
      normalizedText: lower.replaceFirst(_trailingPossessive, ''),
      start: match.start,
      end: match.end,
      sentenceIndex: sentenceIndex,
      isCapitalized: isAllCaps || isTitle,
      isAllCaps: isAllCaps,
      isSentenceInitial: sentenceJustStarted,
    ));
    sentenceJustStarted = false;
  }

  return TokenizedChapter(
    chapterId: chapterId,
    orderIndex: orderIndex,
    tokens: tokens,
    sentenceCount: sentenceIndex + 1,
    normalizedContent: normalized,
  );
}

bool _isSentenceTerminator(String text) {
  if (text.isEmpty) return false;
  final ch = text.codeUnitAt(0);
  return ch == 0x2E /* . */ ||
      ch == 0x21 /* ! */ ||
      ch == 0x3F /* ? */ ||
      ch == 0x3002 /* 。 */ ||
      ch == 0xFF01 /* ！ */ ||
      ch == 0xFF1F /* ？ */;
}
