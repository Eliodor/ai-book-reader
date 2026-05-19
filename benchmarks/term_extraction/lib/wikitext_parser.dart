/// Standard MediaWiki namespaces (and Fandom-extras) that mark a page as
/// non-content — UI, talk, templates, forum threads, etc.
const Set<String> _metaNamespaces = {
  'Category',
  'Category talk',
  'Template',
  'Template talk',
  'User',
  'User talk',
  'User blog',
  'User blog comment',
  'File',
  'File talk',
  'MediaWiki',
  'MediaWiki talk',
  'Help',
  'Help talk',
  'Special',
  'Forum',
  'Forum talk',
  'Board',
  'Board Thread',
  'Topic',
  'Module',
  'Module talk',
  'Talk',
  'Project',
  'Project talk',
  'Thread',
  'Message Wall',
  'Message Wall Greeting',
};

/// Returns true if [pageTitle] belongs to a non-content namespace.
bool isMetaPage(String pageTitle) {
  final idx = pageTitle.indexOf(':');
  if (idx <= 0) return false;
  final namespace = pageTitle.substring(0, idx);
  return _metaNamespaces.contains(namespace);
}

/// Parses wikitext infobox fields. Best-effort — wikitext is irregular and the
/// goal here is "good enough for benchmark ground truth", not a full parser.
class InfoboxExtractor {
  /// Extract the raw value of an infobox field named [fieldName].
  ///
  /// Looks for `|FieldName = value` (case-insensitive on the field name) where
  /// the value continues until the next line starting with `|` or `}}`.
  /// Returns null if the field is missing or empty.
  static String? field(String wikitext, String fieldName) {
    final pattern = RegExp(
      r'^\|\s*' +
          RegExp.escape(fieldName) +
          r'\s*=\s*([\s\S]*?)(?=^\s*\||^\s*\}\}|\Z)',
      caseSensitive: false,
      multiLine: true,
    );
    final match = pattern.firstMatch(wikitext);
    if (match == null) return null;
    final raw = match.group(1)?.trim();
    if (raw == null || raw.isEmpty) return null;
    return raw;
  }

  /// Split a wikitext multi-value field into individual items.
  ///
  /// Handles bullet lists (`* item`, `**subitem`), `<br>` separators, wiki
  /// links (`[[A|B]]` → `B`, `[[A]]` → `A`), bold/italic markers, inline
  /// templates `{{...}}` (removed), and HTML tags.
  static List<String> splitItems(String wikitextValue) {
    var text = wikitextValue
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r"'{2,5}"), '');
    final lines = text.split('\n');
    final items = <String>[];
    for (final raw in lines) {
      var s = raw.trim();
      if (s.isEmpty) continue;
      s = s.replaceFirst(RegExp(r'^[\*#:]+\s*'), '');
      s = s.replaceAllMapped(
        RegExp(r'\[\[([^\|\]]+)(?:\|([^\]]+))?\]\]'),
        (m) => (m.group(2) ?? m.group(1) ?? '').trim(),
      );
      s = _stripBalanced(s, '{{', '}}');
      s = s.replaceAll(RegExp(r'<[^>]+>'), '');
      s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (s.isNotEmpty) items.add(s);
    }
    return items;
  }

  /// Strip balanced pairs of `open`...`close`. Handles a single level of
  /// nesting (enough for `{{template|{{nested}}}}` style cases without going
  /// full recursive descent).
  static String _stripBalanced(String input, String open, String close) {
    final buf = StringBuffer();
    var i = 0;
    var depth = 0;
    while (i < input.length) {
      if (i + open.length <= input.length &&
          input.substring(i, i + open.length) == open) {
        depth++;
        i += open.length;
        continue;
      }
      if (depth > 0 &&
          i + close.length <= input.length &&
          input.substring(i, i + close.length) == close) {
        depth--;
        i += close.length;
        continue;
      }
      if (depth == 0) buf.writeCharCode(input.codeUnitAt(i));
      i++;
    }
    return buf.toString();
  }
}
