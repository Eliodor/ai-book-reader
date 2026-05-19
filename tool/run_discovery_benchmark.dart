// Standalone CLI to run Stage A (Discovery) on an EPUB without any of the
// app's UI or database. Used by benchmarks/term_extraction.
//
//   dart run tool/run_discovery_benchmark.dart \
//     path/to/book.epub  path/to/discovery_output.json [--top-n=1500]
//
// The script reuses the in-repo pipeline code (term_discovery_isolate.dart and
// friends) directly — all of those files are pure Dart. The only Flutter-only
// piece (stopwords_loader.dart's rootBundle) is bypassed by reading the
// stopwords asset from disk here.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'package:ai_book_reader/service/pipeline/chapter_merger.dart';
import 'package:ai_book_reader/service/pipeline/discovery/language_detector.dart';
import 'package:ai_book_reader/service/pipeline/discovery/raw_models.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_constants.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_isolate.dart';
import 'package:ai_book_reader/service/pipeline/discovery/tokenizer.dart';

const String _stopwordsAssetPath = 'assets/data/stopwords-iso.json';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
      'usage: dart run tool/run_discovery_benchmark.dart '
      '<book.epub> <output.json> [--top-n=N]',
    );
    exitCode = 64;
    return;
  }
  final epubPath = args[0];
  final outputPath = args[1];
  int? topNOverride;
  for (final a in args.skip(2)) {
    if (a.startsWith('--top-n=')) {
      topNOverride = int.parse(a.substring('--top-n='.length));
    }
  }

  final epubPathType = FileSystemEntity.typeSync(epubPath);
  if (epubPathType == FileSystemEntityType.notFound) {
    stderr.writeln('Path not found: $epubPath');
    exitCode = 66;
    return;
  }
  if (!File(_stopwordsAssetPath).existsSync()) {
    stderr.writeln(
      'Stopwords asset not found at $_stopwordsAssetPath. '
      'Run this script from the repo root.',
    );
    exitCode = 66;
    return;
  }

  if (epubPathType == FileSystemEntityType.directory) {
    stdout.writeln('Loading EPUBs from directory: $epubPath');
  } else {
    stdout.writeln('Loading EPUB: $epubPath');
  }
  final chapters = await _loadEpubChapters(epubPath);
  stdout.writeln('  ${chapters.length} chapters extracted');
  if (chapters.isEmpty) {
    stderr.writeln('No usable chapters inside the EPUB.');
    exitCode = 65;
    return;
  }
  final totalChars = chapters.fold<int>(0, (s, c) => s + c.content.length);
  stdout.writeln('  $totalChars chars total '
      '(~${(totalChars / 1000).round()}k)');

  stdout.writeln('Loading stopwords from $_stopwordsAssetPath');
  final allStopwords = _loadStopwords(_stopwordsAssetPath);
  stdout.writeln('  ${allStopwords.length} languages');

  stdout.writeln('Detecting language...');
  final detection = _detectLanguageFromChapters(chapters, allStopwords);
  stdout.writeln('  language=${detection.languageCode} '
      'confidence=${detection.confidence.toStringAsFixed(3)} '
      'fallback=${detection.isFallback}');
  final stopwordsForLang =
      allStopwords[detection.languageCode] ?? const <String>{};

  final topN = topNOverride ?? adaptiveDiscoveryTopN(chapters.length);
  if (topNOverride == null) {
    stdout.writeln('Adaptive topN = $topN '
        '(for ${chapters.length} chapters; '
        'see adaptiveDiscoveryTopN in term_discovery_constants.dart)');
  }
  stdout.writeln('Spawning Stage A isolate (topN=$topN)...');
  final clockStart = DateTime.now();
  final output = await _runDiscovery(
    DiscoveryInput(
      chapters: chapters,
      sourceLanguage: detection.languageCode,
      stopwords: stopwordsForLang,
      topN: topN,
    ),
  );
  final wallMs = DateTime.now().difference(clockStart).inMilliseconds;
  stdout.writeln('Discovery finished in ${wallMs}ms wall.');
  stdout.writeln('  raw=${output.stats.rawCandidateCount}  '
      'prefiltered=${output.stats.prefilteredCount}  '
      'final=${output.stats.finalCandidateCount}');
  stdout.writeln('  tokenize=${output.stats.tokenizeMs}ms  '
      'gen=${output.stats.candidateGenMs}ms  '
      'prefilter=${output.stats.prefilterMs}ms  '
      'cvalue=${output.stats.cValueMs}ms');
  stdout.writeln('  cluster=${output.stats.clusterMs}ms  '
      'dp=${output.stats.dispersionMs}ms  '
      'sub=${output.stats.substringMs}ms  '
      'total=${output.stats.totalMs}ms');

  final json = {
    'epub_path': epubPath,
    'discovered_at': DateTime.now().toUtc().toIso8601String(),
    'language': detection.languageCode,
    'language_confidence': detection.confidence,
    'language_fallback': detection.isFallback,
    'top_n': topN,
    'wall_ms': wallMs,
    'stats': {
      'tokenize_ms': output.stats.tokenizeMs,
      'candidate_gen_ms': output.stats.candidateGenMs,
      'prefilter_ms': output.stats.prefilterMs,
      'c_value_ms': output.stats.cValueMs,
      'cluster_ms': output.stats.clusterMs,
      'dispersion_ms': output.stats.dispersionMs,
      'substring_ms': output.stats.substringMs,
      'total_ms': output.stats.totalMs,
      'raw_candidate_count': output.stats.rawCandidateCount,
      'prefiltered_count': output.stats.prefilteredCount,
      'final_candidate_count': output.stats.finalCandidateCount,
      'chapters_processed': chapters.length,
      'total_chars': totalChars,
    },
    'candidates': output.candidates
        .map((c) => {
              'source_text': c.sourceText,
              'normalized_source': c.normalizedSource,
              'candidate_type': c.candidateType,
              'score': c.score,
              'frequency_total': c.frequencyTotal,
              'chapter_count': c.chapterCount,
              'first_chapter_id': c.firstChapterId,
            })
        .toList(),
  };

  File(outputPath).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(json),
  );
  stdout.writeln('Wrote $outputPath '
      '(${output.candidates.length} candidates)');
}

Future<List<ChapterSnapshot>> _loadEpubChapters(String path) async {
  final type = FileSystemEntity.typeSync(path);
  if (type == FileSystemEntityType.directory) {
    final epubs = Directory(path)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.epub'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (epubs.isEmpty) {
      throw StateError('No EPUB files found in $path');
    }
    final all = <ChapterSnapshot>[];
    for (final f in epubs) {
      stdout.writeln('  + ${f.uri.pathSegments.last}');
      final added = await _loadSingleEpubChapters(
        f,
        startOrder: all.length,
      );
      all.addAll(added);
      stdout.writeln('      ${added.length} chapters '
          '(cumulative ${all.length})');
    }
    return all;
  }
  return _loadSingleEpubChapters(File(path), startOrder: 0);
}

/// Spine-aware EPUB → ChapterSnapshot loader. Mirrors what
/// `BookFileParser` + `ChapterMerger` do in the app (and uses the app's
/// `ChapterMerger` directly), but parses the EPUB itself with `package:xml`
/// + `package:html` instead of `package:epub_decoder` — the latter
/// transitively imports `package:flutter` and therefore won't compile under
/// standalone `dart run`.
Future<List<ChapterSnapshot>> _loadSingleEpubChapters(
  File file, {
  required int startOrder,
}) async {
  final raws = _parseEpubSpine(file);
  final merged = ChapterMerger.merge(raws);
  final chapters = <ChapterSnapshot>[];
  for (final m in merged) {
    final content = m.content.trim();
    if (content.isEmpty) continue;
    final orderIndex = startOrder + chapters.length;
    chapters.add(
      ChapterSnapshot(
        id: orderIndex + 1,
        orderIndex: orderIndex,
        content: content,
      ),
    );
  }
  return chapters;
}

/// Pure-Dart EPUB spine extractor:
/// 1. `META-INF/container.xml`  → path to the `.opf` package file
/// 2. `.opf` `<manifest>`       → id-to-href map
/// 3. `.opf` `<spine>`          → ordered list of itemref ids
/// 4. For each spine entry, parse the XHTML body to text + first heading.
///
/// Items outside the spine (cover.xhtml outside spine, TOC.ncx, etc.) are
/// not visited. `ChapterMerger` then collapses `1.1 / 1.2` style splits.
List<RawChapter> _parseEpubSpine(File file) {
  final bytes = file.readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);

  final container = _findInArchive(archive, 'META-INF/container.xml');
  if (container == null) {
    throw StateError('container.xml not found in ${file.path}');
  }
  final containerDoc = XmlDocument.parse(_decodeUtf8(container.content));
  final rootfile = containerDoc.findAllElements('rootfile').firstOrNull;
  final opfPath = rootfile?.getAttribute('full-path');
  if (opfPath == null) {
    throw StateError('OPF rootfile path missing in container.xml');
  }

  final opfEntry = _findInArchive(archive, opfPath);
  if (opfEntry == null) {
    throw StateError('OPF $opfPath not found inside ${file.path}');
  }
  final opfDoc = XmlDocument.parse(_decodeUtf8(opfEntry.content));

  final manifest = <String, String>{};
  for (final item in opfDoc.findAllElements('item')) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');
    if (id != null && href != null) manifest[id] = href;
  }

  final opfDir = p.posix.dirname(opfPath.replaceAll('\\', '/'));
  final raws = <RawChapter>[];
  for (final itemref in opfDoc.findAllElements('itemref')) {
    final idref = itemref.getAttribute('idref');
    if (idref == null) continue;
    final href = manifest[idref];
    if (href == null) continue;
    final fullPath = (opfDir.isEmpty || opfDir == '.')
        ? href
        : p.posix.join(opfDir, href);
    final entry = _findInArchive(archive, fullPath);
    if (entry == null) continue;
    final raw = _decodeUtf8(entry.content);
    final doc = html_parser.parse(raw);
    final body = doc.body;
    if (body == null) continue;

    String title = '';
    for (final sel in const ['h1', 'h2', 'h3']) {
      final el = body.querySelector(sel);
      if (el != null) {
        final t = el.text.trim();
        if (t.isNotEmpty) {
          title = t;
          break;
        }
      }
    }

    final buf = StringBuffer();
    for (final node in body.querySelectorAll('p, div, li')) {
      final t = node.text.trim();
      if (t.isEmpty) continue;
      if (buf.isNotEmpty) buf.write('\n\n');
      buf.write(t);
    }
    final content = buf.toString().trim();
    if (title.isEmpty && content.isEmpty) continue;
    raws.add(RawChapter(title: title, content: content));
  }
  return raws;
}

ArchiveFile? _findInArchive(Archive archive, String path) {
  final norm = path.replaceAll('\\', '/');
  for (final f in archive.files) {
    if (!f.isFile) continue;
    if (f.name.replaceAll('\\', '/') == norm) return f;
  }
  return null;
}

String _decodeUtf8(List<int> bytes) {
  // Strip UTF-8 BOM if present, then decode permissively.
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

Map<String, Set<String>> _loadStopwords(String path) {
  final raw = File(path).readAsStringSync();
  final decoded = jsonDecode(raw) as Map<String, dynamic>;
  final map = <String, Set<String>>{};
  decoded.forEach((key, value) {
    if (value is List) {
      map[key] = value.map((e) => e.toString().toLowerCase()).toSet();
    }
  });
  return map;
}

LanguageDetectionResult _detectLanguageFromChapters(
  List<ChapterSnapshot> chapters,
  Map<String, Set<String>> allStopwords,
) {
  final sample = <String>[];
  var collected = 0;
  for (final ch in chapters.take(3)) {
    final tok = tokenize(
      chapterId: ch.id,
      orderIndex: ch.orderIndex,
      content: ch.content,
    );
    for (final t in tok.tokens) {
      sample.add(t.normalizedText);
    }
    collected += ch.content.length;
    if (collected > 50000) break;
  }
  return detectLanguage(
    sampleTokens: sample,
    stopwordsByLang: allStopwords,
  );
}

Future<DiscoveryOutput> _runDiscovery(DiscoveryInput input) async {
  final main = ReceivePort();
  final completer = Completer<DiscoveryOutput>();
  late StreamSubscription sub;
  sub = main.listen((msg) {
    if (msg is DiscoveryIsolateResult) {
      if (!completer.isCompleted) completer.complete(msg.output);
    } else if (msg is DiscoveryIsolateError) {
      if (!completer.isCompleted) {
        completer.completeError(msg.error, msg.stackTrace);
      }
    } else if (msg == discoveryCancelledResult) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('discovery cancelled'));
      }
    }
    // ignore DiscoveryIsolateReady — we don't issue cancels from this script.
  });
  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
      discoveryIsolateEntry,
      DiscoverySpawnArgs(mainSendPort: main.sendPort, input: input),
      errorsAreFatal: true,
    );
    return await completer.future;
  } finally {
    await sub.cancel();
    main.close();
    isolate?.kill(priority: Isolate.beforeNextEvent);
  }
}
