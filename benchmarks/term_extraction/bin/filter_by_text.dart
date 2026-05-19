import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:term_extraction_benchmark/book_text_loader.dart';
import 'package:term_extraction_benchmark/term_matcher.dart';

/// Filters a raw ground-truth glossary down to only terms that appear in the
/// supplied book text. Both canonical names and epithets are checked; an
/// entry is kept if EITHER the canonical OR at least one epithet survives.
///
/// Usage:
///   dart run bin/filter_by_text.dart <book_path> [--wiki=solo-leveling] [--min-count=1]
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run bin/filter_by_text.dart <book.epub|book.txt> '
      '[--wiki=NAME] [--min-count=N]',
    );
    exitCode = 64;
    return;
  }

  final bookPath = args.first;
  var wiki = 'solo-leveling';
  var minCount = 3;
  for (final a in args.skip(1)) {
    if (a.startsWith('--wiki=')) {
      wiki = a.substring('--wiki='.length);
    } else if (a.startsWith('--min-count=')) {
      minCount = int.parse(a.substring('--min-count='.length));
    }
  }
  stdout.writeln('Settings: wiki=$wiki min-count=$minCount');

  final scriptDir = File(Platform.script.toFilePath()).parent.parent;
  final dataDir = p.join(scriptDir.path, 'data', wiki);
  final rawFile = File(p.join(dataDir, 'ground_truth_raw.json'));
  if (!rawFile.existsSync()) {
    stderr.writeln('Not found: ${rawFile.path}\n'
        'Run `dart run bin/fetch_glossary.dart $wiki` first.');
    exitCode = 66;
    return;
  }

  final pathType = FileSystemEntity.typeSync(bookPath);
  if (pathType == FileSystemEntityType.directory) {
    final epubs = listEpubsInDirectory(bookPath);
    stdout.writeln('Loading directory: $bookPath');
    stdout.writeln('  ${epubs.length} EPUB files:');
    for (final f in epubs) {
      stdout.writeln('    ${p.basename(f.path)}');
    }
  } else {
    stdout.writeln('Loading book: $bookPath');
  }
  final rawText = loadBookText(bookPath);
  stdout.writeln('  ${rawText.length} chars raw, normalizing...');
  // Case-sensitive: a wiki canonical "Red Gate" only counts when the
  // book uses that capitalisation. Lowercase "red gate" (descriptive
  // prose) is not something Stage A would promote — so we don't count
  // it as "present" for ground-truth purposes either.
  final matcher = CaseSensitiveTermMatcher(rawText);

  final raw = jsonDecode(rawFile.readAsStringSync()) as Map<String, dynamic>;
  final categories = raw['categories'] as Map<String, dynamic>;

  final keptCategories = <String, List<Map<String, dynamic>>>{};
  final stats = <String, Map<String, int>>{};

  for (final entry in categories.entries) {
    final catName = entry.key;
    final pages = (entry.value as List).cast<Map<String, dynamic>>();
    final keptPages = <Map<String, dynamic>>[];
    var canonicalsKept = 0;
    var epithetsKept = 0;
    final catWords = catName.toLowerCase().replaceAll('_', ' ').split(' ');
    for (final page in pages) {
      final canonical = page['canonical'] as String;
      // Drop pages whose title is the category name itself (e.g. a page
      // literally called "Shadows" in the Shadows category) — those are
      // self-referential meta-pages, not actual terms.
      final canonLower = canonical.toLowerCase();
      if (canonLower == catName.toLowerCase() ||
          canonLower == catName.toLowerCase().replaceAll('_', ' ') ||
          canonLower == catWords.join(' ')) {
        continue;
      }
      final normCanonical = normalizeForMatch(canonical);
      final canonicalCount = matcher.count(normCanonical);
      final epithetsIn = (page['epithets'] as List?)?.cast<String>() ?? const [];
      final epithetsSurviving = <Map<String, dynamic>>[];
      for (final ep in epithetsIn) {
        final cnt = matcher.count(normalizeForMatch(ep));
        if (cnt >= minCount) {
          epithetsSurviving.add({'text': ep, 'count': cnt});
        }
      }
      final canonicalSurvives = canonicalCount >= minCount;
      if (canonicalSurvives || epithetsSurviving.isNotEmpty) {
        final kept = <String, dynamic>{
          'canonical': canonical,
          if (canonicalSurvives) 'canonical_count': canonicalCount,
          if (epithetsSurviving.isNotEmpty) 'epithets': epithetsSurviving,
        };
        keptPages.add(kept);
        if (canonicalSurvives) canonicalsKept++;
        epithetsKept += epithetsSurviving.length;
      }
    }
    keptCategories[catName] = keptPages;
    stats[catName] = {
      'pages_in': pages.length,
      'pages_kept': keptPages.length,
      'canonicals_kept': canonicalsKept,
      'epithets_kept': epithetsKept,
    };
  }

  final out = {
    'wiki': raw['wiki'],
    'book': p.basename(bookPath),
    'filtered_at': DateTime.now().toUtc().toIso8601String(),
    'min_count': minCount,
    'source': rawFile.path,
    'stats': stats,
    'categories': keptCategories,
  };
  final outFile = File(p.join(dataDir, 'ground_truth.json'));
  outFile.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(out),
  );

  stdout.writeln('');
  stdout.writeln('Wrote ${outFile.path}');
  stdout.writeln('Per-category result:');
  for (final e in stats.entries) {
    final v = e.value;
    stdout.writeln('  ${e.key.padRight(20)} '
        'in=${v['pages_in']!.toString().padLeft(4)}  '
        'kept=${v['pages_kept']!.toString().padLeft(4)}  '
        'canon=${v['canonicals_kept']!.toString().padLeft(4)}  '
        'epi=${v['epithets_kept']}');
  }
}
