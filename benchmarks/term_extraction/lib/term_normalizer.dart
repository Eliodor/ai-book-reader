// Glossary normaliser shared by the LLM-output and Stage-A folders.
//
// Input:  any list of raw term strings (possibly with case / hyphen / plural
//         variants, e.g. ["A rank", "A-Rank", "A-rank", "archdemons",
//         "archdemon", ...]).
// Output: a map { canonical -> sorted variants[] } where each input string is
//         grouped with its case/hyphen-insensitive twins, plural forms are
//         folded into the singular ONLY when the singular also exists in the
//         input, and the canonical form is the variant with the most uppercase
//         letters (ties broken by hyphen presence, then singular form, then
//         alphabetical).
//
// The plural rules are intentionally conservative: a plural folds only when a
// matching singular exists in the same input list. So names like "Igris" or
// "Antares" are never stripped — there is no "Igri" / "Antare" to fold into.

/// Map { canonical display form -> sorted unique variants } produced by
/// [normalizeTerms].
typedef NormalizedGlossary = Map<String, List<String>>;

/// Groups `rawTerms` by case+hyphen+plural and returns a map from each
/// canonical display form to its sorted unique variants.
///
/// [cleanArtifacts] is an extra pre-step aimed at Stage A's noisy output:
/// interjections like `"Ah!"`, `"AHHH!"`, `"Ahhh……"` and their kin all
/// reduce to a single key once trailing/internal punctuation is stripped and
/// any run of >2 identical characters is collapsed to 2. Off by default —
/// LLM glossaries are already clean and don't need this.
NormalizedGlossary normalizeTerms(
  Iterable<String> rawTerms, {
  bool cleanArtifacts = false,
}) {
  // Trim + optional artefact cleanup + drop empties + dedupe (exact-string).
  // We keep both the cleaned form (used as the group identity) and the
  // original display string (used when picking a canonical variant), so
  // "Ah!" still appears next to "Ah" in the variants list.
  final cleanedToOriginals = <String, List<String>>{};
  for (final raw in rawTerms) {
    final t = raw.trim();
    if (t.isEmpty) continue;
    final cleaned = cleanArtifacts ? _cleanArtifacts(t) : t;
    if (cleaned.isEmpty) continue;
    // Drop single-token artefacts that collapsed below the 3-char floor that
    // Stage A's candidate generator itself enforces.
    if (!cleaned.contains(' ') && cleaned.length < 3) continue;
    cleanedToOriginals
        .putIfAbsent(cleaned, () => <String>[])
        .add(cleanArtifacts ? cleaned : t);
  }
  final terms = cleanedToOriginals.keys.toSet();

  // Stage 1: group by case+hyphen-insensitive key.
  final caseGroups = <String, List<String>>{};
  for (final t in terms) {
    caseGroups.putIfAbsent(_stripKey(t), () => <String>[]).add(t);
  }

  // Stage 2: plural folding inside the case-group keyspace.
  final keys = caseGroups.keys.toSet();
  final keyToCanonicalKey = <String, String>{};
  for (final k in keys) {
    String target = k;
    for (final sing in _singularsOfKey(k)) {
      if (keys.contains(sing) && sing != k) {
        target = sing;
        break;
      }
    }
    keyToCanonicalKey[k] = target;
  }

  String resolve(String k) {
    var cur = k;
    final seen = <String>{};
    while (keyToCanonicalKey[cur] != cur) {
      if (!seen.add(cur)) break;
      cur = keyToCanonicalKey[cur]!;
    }
    return cur;
  }

  final mergedGroups = <String, List<String>>{};
  for (final entry in caseGroups.entries) {
    final canKey = resolve(entry.key);
    mergedGroups.putIfAbsent(canKey, () => <String>[]).addAll(entry.value);
  }

  // Stage 3: pick a display form per group.
  final out = <String, List<String>>{};
  for (final entry in mergedGroups.entries) {
    final variants = entry.value.toSet().toList()..sort();
    final canonical = _pickCanonical(variants);
    out[canonical] = variants;
  }
  return out;
}

String _stripKey(String t) {
  var x = t.toLowerCase();
  x = x.replaceAll('-', ' ');
  x = x.replaceAll(RegExp(r'\s+'), ' ').trim();
  return x;
}

/// Stage-A clean-up: strip exclamatory punctuation (`. ! ? , ; : …` and the
/// fullwidth/Chinese variants) and collapse any run of >2 identical
/// characters to 2. Hyphens and apostrophes (curly + straight) are kept —
/// they routinely appear inside legitimate names like "Sung Jin-Woo" or
/// "Don't".
///
/// Examples:
///   "Ah!" / "Ah." / "Ah…" / "Ah……"   → "Ah"
///   "Ahhh!" / "Ahhhh!" / "AHHH!"     → "Ahh" / "AHH"  (case folded later)
///   "U.S.A."                          → "USA"
String _cleanArtifacts(String text) {
  var s = text.trim();
  if (s.isEmpty) return s;
  // Strip end-of-sentence + parenthetical punctuation anywhere it appears.
  // We do NOT strip hyphens, apostrophes (', ’, ‘, ʼ), or quote marks.
  s = s.replaceAll(
    RegExp(r'[.,!?;:…！？，；。、]'),
    '',
  );
  // Collapse runs of the same character (case-sensitive) longer than 2.
  s = _collapseRuns(s);
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s;
}

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

List<String> _singularsOfWord(String w) {
  final out = <String>[];
  if (w.endsWith('ies') && w.length > 3) {
    out.add(w.substring(0, w.length - 3) + 'y');
  }
  if (w.endsWith('es') && w.length > 3) {
    out.add(w.substring(0, w.length - 2));
  }
  if (w.endsWith('s') && w.length > 1 && !w.endsWith('ss')) {
    out.add(w.substring(0, w.length - 1));
  }
  return out;
}

List<String> _singularsOfKey(String key) {
  final words = key.split(' ');
  final out = <String>[];
  for (final sing in _singularsOfWord(words.first)) {
    final copy = List<String>.from(words);
    copy[0] = sing;
    out.add(copy.join(' '));
  }
  if (words.length > 1) {
    for (final sing in _singularsOfWord(words.last)) {
      final copy = List<String>.from(words);
      copy[words.length - 1] = sing;
      out.add(copy.join(' '));
    }
  }
  return out;
}

bool _isPluralForm(String form) {
  final firstWord = form.split(RegExp(r'[\s-]')).first;
  if (firstWord.endsWith('ies') && firstWord.length > 3) return true;
  if (firstWord.endsWith('s') &&
      firstWord.length > 1 &&
      !firstWord.endsWith('ss')) {
    return true;
  }
  return false;
}

int _uppercaseCount(String s) {
  var n = 0;
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    if (c != c.toLowerCase() && c == c.toUpperCase()) n++;
  }
  return n;
}

String _pickCanonical(List<String> variants) {
  String? best;
  int bestScore = -1;
  for (final v in variants) {
    var s = _uppercaseCount(v) * 1000;
    if (v.contains('-')) s += 50;
    if (!_isPluralForm(v)) s += 5;
    if (s > bestScore ||
        (s == bestScore && (best == null || v.compareTo(best) < 0))) {
      bestScore = s;
      best = v;
    }
  }
  return best!;
}
