import 'dart:convert';

/// Tolerant extraction of a JSON value from an LLM response.
///
/// Models frequently wrap their answer in markdown fences, prepend prose, or
/// trail extra commentary. This helper:
/// 1. Strips ``` and ```json fences (and anything before them).
/// 2. Scans for the first `[` or `{` and finds the matching close via a
///    bracket counter that respects strings and escapes.
/// 3. Calls [jsonDecode] on the slice.
///
/// Returns `null` on failure rather than throwing — callers usually want to
/// retry with a stricter prompt rather than crashing.
Object? extractJson(String raw) {
  final stripped = _stripFences(raw);
  for (var i = 0; i < stripped.length; i++) {
    final ch = stripped[i];
    if (ch == '[' || ch == '{') {
      final close = _matchBracket(stripped, i);
      if (close < 0) continue;
      final slice = stripped.substring(i, close + 1);
      try {
        return jsonDecode(slice);
      } catch (_) {
        // try next opener
        continue;
      }
    }
  }
  return null;
}

/// Tries [extractJson] and casts to `List<int>`. Returns `null` if the value
/// is not a flat list of integers (the shape Stage B's filter prompt asks for).
List<int>? extractIntList(String raw) {
  final value = extractJson(raw);
  if (value is! List) return null;
  final out = <int>[];
  for (final item in value) {
    if (item is int) {
      out.add(item);
    } else if (item is num) {
      out.add(item.toInt());
    } else {
      return null;
    }
  }
  return out;
}

/// Same as [extractJson] but cast to `Map<String, String?>` — the shape Stage C
/// mining expects (source term -> target translation or null).
Map<String, String?>? extractStringMap(String raw) {
  final value = extractJson(raw);
  if (value is! Map) return null;
  final out = <String, String?>{};
  value.forEach((key, val) {
    final k = key.toString();
    if (val == null) {
      out[k] = null;
    } else {
      out[k] = val.toString();
    }
  });
  return out;
}

/// Heuristic: the last non-whitespace character of the response suggests the
/// model was truncated. We accept the response is complete only if it closes
/// the JSON shape we expect.
bool looksTruncated(String raw, {required bool expectArray}) {
  final trimmed = raw.trimRight();
  if (trimmed.isEmpty) return true;
  final last = trimmed[trimmed.length - 1];
  if (expectArray) return last != ']';
  return last != '}';
}

String _stripFences(String raw) {
  // Common pattern: ```json\n...\n``` or ```\n...\n```.
  final fenceStart = RegExp(r'```(?:json|JSON)?\s*');
  final match = fenceStart.firstMatch(raw);
  if (match == null) return raw;
  final afterStart = raw.substring(match.end);
  final closeIdx = afterStart.indexOf('```');
  if (closeIdx < 0) return afterStart;
  return afterStart.substring(0, closeIdx);
}

int _matchBracket(String s, int openIdx) {
  final open = s[openIdx];
  final close = open == '[' ? ']' : '}';
  var depth = 0;
  var inString = false;
  var escape = false;
  for (var i = openIdx; i < s.length; i++) {
    final ch = s[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (ch == '\\') {
      escape = true;
      continue;
    }
    if (ch == '"') {
      inString = !inString;
      continue;
    }
    if (inString) continue;
    if (ch == open) {
      depth++;
    } else if (ch == close) {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}
