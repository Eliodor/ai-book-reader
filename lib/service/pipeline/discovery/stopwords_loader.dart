import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Loads the per-language stopword sets from `assets/data/stopwords-iso.json`.
///
/// The JSON ships as `Map<String, List<String>>` keyed by ISO 639-1 language
/// codes (e.g. `en`, `ru`, `uk`, `de`). The asset is small enough (~200 KB) to
/// keep cached in memory after first load.
class StopwordsLoader {
  StopwordsLoader();

  Map<String, Set<String>>? _cache;
  Future<Map<String, Set<String>>>? _inflight;

  Future<Map<String, Set<String>>> loadAll() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _inflight ??= _load();
  }

  Future<Map<String, Set<String>>> _load() async {
    final raw = await rootBundle.loadString('assets/data/stopwords-iso.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final map = <String, Set<String>>{};
    decoded.forEach((key, value) {
      if (value is List) {
        map[key] = value.map((e) => e.toString().toLowerCase()).toSet();
      }
    });
    _cache = map;
    _inflight = null;
    return map;
  }

  /// Returns the stopword set for [lang] (case-insensitive). Empty set if the
  /// language is missing — callers should treat that as "no filter".
  Future<Set<String>> forLanguage(String lang) async {
    final all = await loadAll();
    return all[lang.toLowerCase()] ?? <String>{};
  }
}

final stopwordsLoader = StopwordsLoader();
