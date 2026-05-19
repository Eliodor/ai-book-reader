import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

class FandomApiException implements Exception {
  FandomApiException(this.message);
  final String message;
  @override
  String toString() => 'FandomApiException: $message';
}

class FandomApi {
  FandomApi({
    required this.wikiSubdomain,
    required this.cacheDir,
    this.requestDelay = const Duration(milliseconds: 300),
    http.Client? client,
  }) : _client = client ?? http.Client();

  final String wikiSubdomain;
  final String cacheDir;
  final Duration requestDelay;
  final http.Client _client;

  String get _endpoint => 'https://$wikiSubdomain.fandom.com/api.php';

  /// Return only the direct page members of [category] (no recursion).
  /// Each entry is the raw `categorymembers` element: `{pageid, ns, title}`.
  Future<List<Map<String, dynamic>>> categoryMembers(String category) async {
    return _categoryMembersPaged(
      category,
      cmtype: 'page',
      cachePrefix: 'cat',
    );
  }

  /// Return all pages in [category] plus all of its descendant subcategories,
  /// up to [maxDepth] nesting levels. Pages are de-duplicated by title.
  /// Subcategory traversal is breadth-first with a visited set to handle the
  /// occasional category cycle some wikis have.
  Future<List<Map<String, dynamic>>> categoryMembersRecursive(
    String category, {
    int maxDepth = 4,
  }) async {
    final visited = <String>{category};
    final byTitle = <String, Map<String, dynamic>>{};
    final queue = <_PendingCategory>[_PendingCategory(category, 0)];

    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      final members = await _categoryMembersPaged(
        current.name,
        cmtype: 'page|subcat',
        cachePrefix: 'rcat',
      );
      for (final m in members) {
        final ns = m['ns'] as int?;
        final title = m['title'] as String;
        if (ns == 14) {
          if (current.depth >= maxDepth) continue;
          final subName = title.substring('Category:'.length);
          if (!visited.add(subName)) continue;
          queue.add(_PendingCategory(subName, current.depth + 1));
        } else {
          byTitle[title] = m;
        }
      }
    }
    return byTitle.values.toList();
  }

  Future<List<Map<String, dynamic>>> _categoryMembersPaged(
    String category, {
    required String cmtype,
    required String cachePrefix,
  }) async {
    final all = <Map<String, dynamic>>[];
    String? cont;
    var pageIndex = 0;
    while (true) {
      final params = <String, String>{
        'action': 'query',
        'list': 'categorymembers',
        'cmtitle': 'Category:$category',
        'cmlimit': '500',
        'cmtype': cmtype,
        'format': 'json',
        if (cont != null) 'cmcontinue': cont,
      };
      final data = await _get(
        params,
        cacheKey: '${cachePrefix}_${_safeFilename(category)}_$pageIndex',
      );
      final query = data['query'] as Map<String, dynamic>?;
      final members = (query?['categorymembers'] as List?) ?? const [];
      for (final m in members) {
        all.add(Map<String, dynamic>.from(m as Map));
      }
      cont = (data['continue'] as Map?)?['cmcontinue'] as String?;
      if (cont == null) break;
      pageIndex++;
    }
    return all;
  }

  /// Fetch the wikitext source of a page. Returns null if not found.
  Future<String?> pageWikitext(String pageTitle) async {
    final data = await _get({
      'action': 'parse',
      'page': pageTitle,
      'prop': 'wikitext',
      'format': 'json',
    }, cacheKey: 'wt_${_safeFilename(pageTitle)}');
    if (data['error'] != null) return null;
    final parse = data['parse'] as Map<String, dynamic>?;
    if (parse == null) return null;
    return (parse['wikitext'] as Map?)?['*'] as String?;
  }

  void close() => _client.close();

  Future<Map<String, dynamic>> _get(
    Map<String, String> params, {
    required String cacheKey,
  }) async {
    final cacheFile = File(p.join(cacheDir, '$cacheKey.json'));
    if (cacheFile.existsSync()) {
      try {
        return jsonDecode(cacheFile.readAsStringSync()) as Map<String, dynamic>;
      } catch (_) {
        // Corrupt cache entry — refetch.
      }
    }
    final uri = Uri.parse(_endpoint).replace(queryParameters: params);
    final response = await _client.get(uri, headers: const {
      'User-Agent':
          'AIBookReader-benchmark/1.0 (research; +https://github.com/eliodor/AIBookReader)',
      'Accept': 'application/json',
    });
    if (response.statusCode != 200) {
      throw FandomApiException(
        'HTTP ${response.statusCode} for $uri\n${_truncate(response.body, 300)}',
      );
    }
    cacheFile.parent.createSync(recursive: true);
    cacheFile.writeAsStringSync(response.body);
    await Future<void>.delayed(requestDelay);
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  static String _safeFilename(String s) =>
      s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  static String _truncate(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}...';
}

class _PendingCategory {
  _PendingCategory(this.name, this.depth);
  final String name;
  final int depth;
}
