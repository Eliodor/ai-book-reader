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

NormalizedGlossary normalizeTerms(Iterable<String> rawTerms) {
  // Trim + drop empties + dedupe (exact-string).
  final terms = <String>{};
  for (final raw in rawTerms) {
    final t = raw.trim();
    if (t.isNotEmpty) terms.add(t);
  }

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
