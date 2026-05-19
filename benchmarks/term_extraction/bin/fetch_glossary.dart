import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:term_extraction_benchmark/fandom_api.dart';
import 'package:term_extraction_benchmark/wikitext_parser.dart';

/// Categories on `solo-leveling.fandom.com` worth pulling for ground truth.
/// Pages in any non-existent category are silently skipped.
const List<String> _defaultCategories = [
  'Characters',
  'Magic_Beasts',
  'Shadows',
  'Skills',
  'Abilities',
  'Items',
  'Weapons',
  'Locations',
  'Organizations',
  'Guilds',
  'Hunters',
  'Monarchs',
  'Rulers',
  'Dungeons',
  'Gates',
];

Future<void> main(List<String> args) async {
  final wiki = args.isNotEmpty ? args[0] : 'solo-leveling';
  final categories = args.length > 1 ? args.sublist(1) : _defaultCategories;

  final scriptDir = File(Platform.script.toFilePath()).parent.parent;
  final dataDir = p.join(scriptDir.path, 'data', wiki);
  final cacheDir = p.join(dataDir, 'cache');
  Directory(cacheDir).createSync(recursive: true);

  final api = FandomApi(wikiSubdomain: wiki, cacheDir: cacheDir);
  final result = <String, List<Map<String, dynamic>>>{};
  final stats = <String, Map<String, int>>{};

  for (final cat in categories) {
    stdout.writeln('=== Category: $cat ===');
    final List<Map<String, dynamic>> members;
    try {
      members = await api.categoryMembersRecursive(cat);
    } on FandomApiException catch (e) {
      stdout.writeln('  [skip] $e');
      continue;
    }

    if (members.isEmpty) {
      stdout.writeln('  [empty]');
      continue;
    }

    final pages = members
        .where((m) => !isMetaPage(m['title'] as String))
        .toList();
    stdout.writeln('  ${pages.length} content pages (${members.length} raw)');

    final entries = <Map<String, dynamic>>[];
    var withEpithet = 0;
    var processed = 0;
    for (final pg in pages) {
      final title = pg['title'] as String;
      processed++;
      if (processed % 25 == 0 || processed == pages.length) {
        stdout.writeln('  [$processed/${pages.length}] $title');
      }
      String? wikitext;
      try {
        wikitext = await api.pageWikitext(title);
      } on FandomApiException catch (e) {
        stdout.writeln('    fetch failed: $e');
      }
      final entry = <String, dynamic>{'canonical': title};
      if (wikitext != null) {
        final epithetRaw = InfoboxExtractor.field(wikitext, 'Epithet');
        if (epithetRaw != null) {
          final list = InfoboxExtractor.splitItems(epithetRaw);
          if (list.isNotEmpty) {
            entry['epithets'] = list;
            withEpithet++;
          }
        }
      }
      entries.add(entry);
    }

    result[cat] = entries;
    stats[cat] = {'pages': entries.length, 'with_epithet': withEpithet};
  }

  api.close();

  final raw = {
    'wiki': wiki,
    'fetched_at': DateTime.now().toUtc().toIso8601String(),
    'stats': stats,
    'categories': result,
  };
  final outFile = File(p.join(dataDir, 'ground_truth_raw.json'));
  outFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(raw),
  );
  stdout.writeln('');
  stdout.writeln('Wrote ${outFile.path}');
  stdout.writeln('Summary:');
  for (final e in stats.entries) {
    final v = e.value;
    stdout.writeln('  ${e.key.padRight(20)} '
        'pages=${v['pages']}  with_epithet=${v['with_epithet']}');
  }
}
