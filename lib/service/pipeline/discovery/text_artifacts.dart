/// Stage-A surface-form cleanup applied to every candidate before it is
/// committed to the in-memory map. Without this, exclamations and stutters
/// that ride inside quoted spans ("Ah!", "Ahhh!", "AHHH!!!", "Argh……") each
/// become their own candidate and flood the noise floor downstream.
///
/// Two cheap rules:
///   1. Strip end-of-sentence and listing punctuation: `. , ! ? ; : …` plus
///      their CJK fullwidth siblings. Hyphens, apostrophes (curly and
///      straight), and quote marks are preserved — they appear inside
///      legitimate names like "Sung Jin-Woo" or "Don't".
///   2. Collapse any run of >2 identical characters down to 2: `Ahhh` → `Ahh`,
///      `Arghhhhhh` → `Arghh`. No natural English / Ukrainian / Russian word
///      has three identical letters in a row.
String cleanTermArtifacts(String input) {
  var s = input.trim();
  if (s.isEmpty) return s;
  s = s.replaceAll(_punct, '');
  s = _collapseRuns(s);
  s = s.replaceAll(_whitespace, ' ').trim();
  return s;
}

final RegExp _punct = RegExp(r'[.,!?;:…！？，；。、]');
final RegExp _whitespace = RegExp(r'\s+');

String _collapseRuns(String s) {
  if (s.length < 3) return s;
  final buf = StringBuffer();
  String prev1 = '';
  String prev2 = '';
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    if (c == prev1 && c == prev2) {
      continue;
    }
    buf.write(c);
    prev2 = prev1;
    prev1 = c;
  }
  return buf.toString();
}
