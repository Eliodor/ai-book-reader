import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Verdict for a single mined `(source, target)` translation pair.
class PostfilterResult {
  const PostfilterResult({required this.keep, this.reason});
  final bool keep;
  final String? reason;
}

/// Ports the Python `_filter_mining_results` heuristics
/// (`candidate_guided_miner_step.py:308-345`) plus three extras:
/// - reject if target length is 0 or > 5× source length (runaway translation);
/// - reject if target is purely digits/punctuation;
/// - reject if NFD-folded lower-cased forms are identical (catches latin
///   transliterations that slip through).
PostfilterResult postfilterPair({
  required String source,
  required String? target,
}) {
  if (target == null) return const PostfilterResult(keep: false, reason: 'null');
  final trimmed = target.trim();
  if (trimmed.isEmpty) {
    return const PostfilterResult(keep: false, reason: 'empty');
  }
  if (trimmed.length > 5 * source.length && source.isNotEmpty) {
    return const PostfilterResult(keep: false, reason: 'too-long');
  }
  if (_isPureDigitsOrPunctuation(trimmed)) {
    return const PostfilterResult(keep: false, reason: 'digits-or-punct');
  }
  if (_fold(trimmed) == _fold(source)) {
    return const PostfilterResult(keep: false, reason: 'echo-source');
  }
  // Python heuristic: if both strings are 50%+ ASCII and word-overlap > 50%,
  // it's likely the translator just copied the source. Apply only when target
  // looks ASCII to avoid pruning legitimate Latin-script translations.
  if (_isMostlyAscii(trimmed)) {
    final overlap = _wordOverlap(source, trimmed);
    if (overlap >= 0.5) {
      return const PostfilterResult(keep: false, reason: 'source-echo-ascii');
    }
  }
  return const PostfilterResult(keep: true);
}

/// Returns the dedup key for [target] — Unicode NFC + lower-case + whitespace
/// normalised. Stage C uses this as the `term_target_normalized` column.
String normalizeTargetKey(String target) {
  final nfc = unorm.nfc(target.trim().toLowerCase());
  return nfc.replaceAll(_whitespaceRun, ' ');
}

final RegExp _whitespaceRun = RegExp(r'\s+');
final RegExp _pureDigitsOrPunct =
    RegExp(r'^[\d\s\p{P}\p{S}]+$', unicode: true);
final RegExp _combiningMarks = RegExp(r'\p{M}', unicode: true);

bool _isPureDigitsOrPunctuation(String s) {
  return _pureDigitsOrPunct.hasMatch(s);
}

String _fold(String s) {
  final nfd = unorm.nfd(s.toLowerCase());
  // strip combining marks (NFD diacritics) so "café" == "cafe".
  return nfd.replaceAll(_combiningMarks, '');
}

bool _isMostlyAscii(String s) {
  if (s.isEmpty) return false;
  var ascii = 0;
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) < 128) ascii++;
  }
  return ascii / s.length >= 0.8;
}

double _wordOverlap(String a, String b) {
  final wordsA = a.toLowerCase().split(_whitespaceRun).where((w) => w.isNotEmpty).toSet();
  final wordsB = b.toLowerCase().split(_whitespaceRun).where((w) => w.isNotEmpty).toSet();
  if (wordsA.isEmpty || wordsB.isEmpty) return 0;
  final inter = wordsA.intersection(wordsB).length;
  return inter / (wordsA.length < wordsB.length ? wordsA.length : wordsB.length);
}
