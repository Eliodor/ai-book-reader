import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:term_extraction_benchmark/benchmark_metrics.dart';

const String _usage = '''
Compare term-extraction pipeline output against ground-truth glossary.

Recall mode (default). Pick ONE of these candidate sources:
  Standalone Stage A run (no DB, no app):
    dart run bin/run_benchmark.dart \\
      --discovery-output=<path-to-discovery_output.json> \\
      [--wiki=solo-leveling] [--precision-sample=200]

  On-device DB (after Stage A+B has run inside the app):
    dart run bin/run_benchmark.dart \\
      --db=<path-to-app_database.db> --book-id=<id> \\
      [--wiki=solo-leveling] [--precision-sample=200]

  Plain term list (any pre-curated glossary or LLM output — JSON array of strings):
    dart run bin/run_benchmark.dart \\
      --terms-json=<path-to-array-of-strings.json> \\
      [--wiki=solo-leveling] [--precision-sample=200]

  All three modes join candidates with data/<wiki>/ground_truth.json and print
  recall (strict + loose) per category. --db mode also splits Stage A vs
  Stage A+B (filtered) when the LLM filter has run. Writes precision_sample.csv
  next to ground_truth.json for manual labelling.

Precision aggregation mode:
  dart run bin/run_benchmark.dart aggregate-precision <labelled.csv>

  Reads a CSV labelled by hand (is_term column = 1/0/?) and prints
  precision = labelled-yes / (labelled-yes + labelled-no).
''';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage);
    return;
  }

  if (args.first == 'aggregate-precision') {
    if (args.length != 2) {
      stderr.writeln('aggregate-precision needs exactly one CSV path');
      exitCode = 64;
      return;
    }
    _aggregatePrecision(args[1]);
    return;
  }

  String? dbPath;
  String? discoveryOutputPath;
  String? termsJsonPath;
  String? groundTruthOverride;
  int? bookId;
  var wiki = 'solo-leveling';
  var precisionSample = 200;
  for (final a in args) {
    if (a.startsWith('--db=')) {
      dbPath = a.substring('--db='.length);
    } else if (a.startsWith('--discovery-output=')) {
      discoveryOutputPath = a.substring('--discovery-output='.length);
    } else if (a.startsWith('--terms-json=')) {
      termsJsonPath = a.substring('--terms-json='.length);
    } else if (a.startsWith('--ground-truth=')) {
      groundTruthOverride = a.substring('--ground-truth='.length);
    } else if (a == '--db' || a == '-d') {
      stderr.writeln('Use --db=<path> form.');
      exitCode = 64;
      return;
    } else if (a.startsWith('--book-id=')) {
      bookId = int.parse(a.substring('--book-id='.length));
    } else if (a.startsWith('--wiki=')) {
      wiki = a.substring('--wiki='.length);
    } else if (a.startsWith('--precision-sample=')) {
      precisionSample = int.parse(a.substring('--precision-sample='.length));
    }
  }
  final sourceCount = [dbPath, discoveryOutputPath, termsJsonPath]
      .where((s) => s != null)
      .length;
  if (sourceCount == 0) {
    stderr.writeln('Need one of: --discovery-output=<path>, '
        '--db=<path> --book-id=<id>, or --terms-json=<path>.\n\n$_usage');
    exitCode = 64;
    return;
  }
  if (sourceCount > 1) {
    stderr.writeln('--db, --discovery-output and --terms-json are mutually exclusive.');
    exitCode = 64;
    return;
  }
  if (dbPath != null && bookId == null) {
    stderr.writeln('--db requires --book-id=<id>.');
    exitCode = 64;
    return;
  }
  if (dbPath != null && !File(dbPath).existsSync()) {
    stderr.writeln('DB file not found: $dbPath');
    exitCode = 66;
    return;
  }
  if (discoveryOutputPath != null && !File(discoveryOutputPath).existsSync()) {
    stderr.writeln('Discovery JSON not found: $discoveryOutputPath');
    exitCode = 66;
    return;
  }
  if (termsJsonPath != null && !File(termsJsonPath).existsSync()) {
    stderr.writeln('Terms JSON not found: $termsJsonPath');
    exitCode = 66;
    return;
  }

  final scriptDir = File(Platform.script.toFilePath()).parent.parent;
  final dataDir = p.join(scriptDir.path, 'data', wiki);
  final gtFile = groundTruthOverride != null
      ? File(groundTruthOverride)
      : File(p.join(dataDir, 'ground_truth.json'));
  if (!gtFile.existsSync()) {
    if (groundTruthOverride != null) {
      stderr.writeln('Ground truth not found: ${gtFile.path}');
    } else {
      stderr.writeln('Filtered ground truth not found: ${gtFile.path}\n'
          'Run `dart run bin/filter_by_text.dart <book>` first.');
    }
    exitCode = 66;
    return;
  }

  final gtTerms = _loadGroundTruth(gtFile);
  stdout.writeln('Ground truth: ${gtTerms.length} terms across '
      '${gtTerms.map((t) => t.category).toSet().length} categories '
      '(${gtFile.path})');

  final List<Candidate> allCandidates;
  final bool stageBKnown;
  if (termsJsonPath != null) {
    allCandidates = _loadCandidatesFromTermsJson(File(termsJsonPath));
    stageBKnown = false;
    stdout.writeln('Candidates: ${allCandidates.length} loaded from terms JSON '
        '(plain string array — no scores / chapter counts)');
  } else if (discoveryOutputPath != null) {
    allCandidates = _loadCandidatesFromJson(File(discoveryOutputPath));
    stageBKnown = false;
    stdout.writeln('Candidates: ${allCandidates.length} loaded from JSON '
        '(Stage A only — no filter status available)');
  } else {
    final Database db;
    try {
      db = sqlite3.open(dbPath!);
    } on Exception catch (e) {
      stderr.writeln(
        'Failed to open SQLite DB: $e\n\n'
        'On Windows the standalone `sqlite3` package needs sqlite3.dll '
        'on PATH.\nEasiest fix: download https://www.sqlite.org/download.html '
        '(Precompiled Binaries for Windows → sqlite-dll-win-x64-...zip), \n'
        'extract sqlite3.dll into this folder or somewhere on PATH.',
      );
      exitCode = 70;
      return;
    }
    allCandidates = _loadCandidates(db, bookId!);
    db.dispose();
    stageBKnown = true;
    stdout.writeln(
      'Candidates: ${allCandidates.length} loaded from DB for book_id=$bookId',
    );
  }

  final stageACandidates = allCandidates;
  final stageBCandidates = stageBKnown
      ? allCandidates.where((c) => c.status != 'rejected').toList()
      : allCandidates;
  stdout.writeln('  Stage A pool:   ${stageACandidates.length}');
  if (stageBKnown) {
    stdout.writeln('  Stage A+B pool: ${stageBCandidates.length} '
        '(excluded ${stageACandidates.length - stageBCandidates.length} rejected)');
  } else {
    stdout.writeln(
      '  Stage A+B pool: n/a (run via --db once the LLM filter has run)',
    );
  }
  stdout.writeln('');

  final rowsA = computeRecallByCategory(gtTerms, stageACandidates);
  final rowsAB = stageBKnown
      ? computeRecallByCategory(gtTerms, stageBCandidates)
      : rowsA; // duplicate so the printer always has two columns
  _printRecallTable(rowsA, rowsAB, stageBKnown: stageBKnown);

  // Precision sample.
  final sample = _sampleCandidates(stageACandidates, precisionSample);
  final precisionCsv = File(p.join(dataDir, 'precision_sample.csv'));
  _writePrecisionCsv(precisionCsv, sample);
  stdout.writeln('');
  stdout.writeln('Precision sample (${sample.length} rows) -> '
      '${precisionCsv.path}');
  stdout.writeln('  Fill the is_term column with 1 / 0 / ? '
      '(yes / no / unsure), save, then:');
  stdout.writeln('  dart run bin/run_benchmark.dart aggregate-precision '
      '${precisionCsv.path}');
}

List<GtTerm> _loadGroundTruth(File file) {
  final raw = jsonDecode(file.readAsStringSync());
  // Flat string array — every entry becomes one term in a single category.
  if (raw is List) {
    final seen = <String>{};
    final terms = <GtTerm>[];
    for (final item in raw) {
      if (item is! String) continue;
      final canonical = item.trim();
      if (canonical.isEmpty) continue;
      if (!seen.add(canonical)) continue;
      terms.add(GtTerm(
        category: 'All',
        canonical: canonical,
        isEpithet: false,
      ));
    }
    return terms;
  }
  // Categorised wiki shape: { categories: { Cat: [{canonical, epithets[]}] } }.
  final map = raw as Map<String, dynamic>;
  final categories = map['categories'] as Map<String, dynamic>;
  final terms = <GtTerm>[];
  for (final catEntry in categories.entries) {
    final cat = catEntry.key;
    final list = (catEntry.value as List).cast<Map<String, dynamic>>();
    for (final page in list) {
      final canonical = page['canonical'] as String;
      if (page['canonical_count'] != null) {
        terms.add(GtTerm(
          category: cat,
          canonical: canonical,
          isEpithet: false,
        ));
      }
      final epithets = (page['epithets'] as List?)?.cast<Map<String, dynamic>>();
      if (epithets != null) {
        for (final ep in epithets) {
          terms.add(GtTerm(
            category: cat,
            canonical: ep['text'] as String,
            isEpithet: true,
          ));
        }
      }
    }
  }
  return terms;
}

List<Candidate> _loadCandidatesFromJson(File file) {
  final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final list = (raw['candidates'] as List).cast<Map<String, dynamic>>();
  var id = 0;
  return list
      .map(
        (c) => Candidate(
          id: ++id,
          sourceText: c['source_text'] as String,
          normalizedSource: c['normalized_source'] as String,
          candidateType: (c['candidate_type'] as String?) ?? 'phrase',
          score: (c['score'] as num).toDouble(),
          frequencyTotal: c['frequency_total'] as int,
          chapterCount: c['chapter_count'] as int,
          status: 'candidate',
        ),
      )
      .toList();
}

/// Wraps a plain `["term", "term", ...]` JSON array into [Candidate]s so the
/// same recall logic can evaluate any pre-curated glossary, including LLM
/// output. Score / freq / chapter_count are placeholders — they don't affect
/// recall, only the precision sample CSV.
List<Candidate> _loadCandidatesFromTermsJson(File file) {
  final raw = jsonDecode(file.readAsStringSync());
  if (raw is! List) {
    throw FormatException(
        'Expected a top-level JSON array of strings in ${file.path}');
  }
  var id = 0;
  final seen = <String>{};
  final out = <Candidate>[];
  for (final item in raw) {
    if (item is! String) continue;
    final text = item.trim();
    if (text.isEmpty) continue;
    if (!seen.add(text)) continue;
    out.add(Candidate(
      id: ++id,
      sourceText: text,
      normalizedSource: text.toLowerCase(),
      candidateType: 'glossary',
      score: 1.0,
      frequencyTotal: 1,
      chapterCount: 1,
      status: 'candidate',
    ));
  }
  return out;
}

List<Candidate> _loadCandidates(Database db, int bookId) {
  final result = db.select(
    '''
    SELECT id, source_text, normalized_source, candidate_type,
           score, frequency_total, chapter_count, status
    FROM tb_term_candidates
    WHERE book_id = ?
    ORDER BY score DESC
    ''',
    [bookId],
  );
  return result
      .map(
        (row) => Candidate(
          id: row['id'] as int,
          sourceText: row['source_text'] as String,
          normalizedSource: row['normalized_source'] as String,
          candidateType: row['candidate_type'] as String,
          score: (row['score'] as num).toDouble(),
          frequencyTotal: row['frequency_total'] as int,
          chapterCount: row['chapter_count'] as int,
          status: row['status'] as String,
        ),
      )
      .toList();
}

void _printRecallTable(
  List<CategoryRecall> a,
  List<CategoryRecall> ab, {
  required bool stageBKnown,
}) {
  final byCat = <String, (CategoryRecall, CategoryRecall)>{};
  for (final r in a) {
    final pair = ab.firstWhere((x) => x.category == r.category);
    byCat[r.category] = (r, pair);
  }
  stdout.writeln('Recall by category:');
  if (stageBKnown) {
    stdout.writeln(''
        '${'Category'.padRight(18)}  '
        '${'terms'.padLeft(5)}  '
        '${'A strict'.padLeft(9)}  '
        '${'A loose'.padLeft(9)}  '
        '${'A+B strict'.padLeft(11)}  '
        '${'A+B loose'.padLeft(11)}');
  } else {
    stdout.writeln(''
        '${'Category'.padRight(18)}  '
        '${'terms'.padLeft(5)}  '
        '${'strict'.padLeft(9)}  '
        '${'loose'.padLeft(9)}');
  }
  stdout.writeln('-' * (stageBKnown ? 80 : 50));
  final sortedKeys = byCat.keys.toList()..sort();
  sortedKeys
    ..remove('TOTAL')
    ..add('TOTAL');
  for (final cat in sortedKeys) {
    final (ar, abr) = byCat[cat]!;
    if (stageBKnown) {
      stdout.writeln(''
          '${cat.padRight(18)}  '
          '${ar.terms.toString().padLeft(5)}  '
          '${_pct(ar.recallStrict).padLeft(9)}  '
          '${_pct(ar.recallLoose).padLeft(9)}  '
          '${_pct(abr.recallStrict).padLeft(11)}  '
          '${_pct(abr.recallLoose).padLeft(11)}');
    } else {
      stdout.writeln(''
          '${cat.padRight(18)}  '
          '${ar.terms.toString().padLeft(5)}  '
          '${_pct(ar.recallStrict).padLeft(9)}  '
          '${_pct(ar.recallLoose).padLeft(9)}');
    }
  }
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

List<Candidate> _sampleCandidates(List<Candidate> all, int n) {
  if (all.length <= n) return List.of(all);
  final rng = Random(42);
  final pool = List<Candidate>.of(all)..shuffle(rng);
  return pool.take(n).toList();
}

void _writePrecisionCsv(File out, List<Candidate> sample) {
  final buf = StringBuffer();
  buf.writeln('candidate_id,source_text,score,frequency_total,'
      'chapter_count,status,candidate_type,is_term,note');
  for (final c in sample) {
    buf.writeln([
      c.id,
      _csv(c.sourceText),
      c.score.toStringAsFixed(4),
      c.frequencyTotal,
      c.chapterCount,
      c.status,
      c.candidateType,
      '',
      '',
    ].join(','));
  }
  out.writeAsStringSync('﻿${buf.toString()}'); // BOM for Excel
}

String _csv(String v) {
  if (v.contains(',') || v.contains('"') || v.contains('\n')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

void _aggregatePrecision(String csvPath) {
  final file = File(csvPath);
  if (!file.existsSync()) {
    stderr.writeln('Not found: $csvPath');
    exitCode = 66;
    return;
  }
  final lines = file.readAsLinesSync();
  if (lines.isEmpty) {
    stderr.writeln('Empty CSV.');
    exitCode = 65;
    return;
  }
  final header = _parseCsvLine(lines.first);
  final isTermIdx = header.indexOf('is_term');
  if (isTermIdx < 0) {
    stderr.writeln('Missing is_term column. Header: $header');
    exitCode = 65;
    return;
  }
  var yes = 0;
  var no = 0;
  var unsure = 0;
  var unlabeled = 0;
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final fields = _parseCsvLine(line);
    if (fields.length <= isTermIdx) {
      unlabeled++;
      continue;
    }
    final label = fields[isTermIdx].trim().toLowerCase();
    switch (label) {
      case '1' || 'y' || 'yes' || '+':
        yes++;
      case '0' || 'n' || 'no' || '-':
        no++;
      case '?':
        unsure++;
      case '':
        unlabeled++;
      default:
        stderr.writeln('Row $i: unknown label "${fields[isTermIdx]}", '
            'treating as unlabelled.');
        unlabeled++;
    }
  }
  final scored = yes + no;
  final precision = scored == 0 ? 0.0 : yes / scored;
  stdout.writeln('Precision sample:');
  stdout.writeln('  yes        : $yes');
  stdout.writeln('  no         : $no');
  stdout.writeln('  unsure     : $unsure');
  stdout.writeln('  unlabelled : $unlabeled');
  stdout.writeln('  precision  : ${(precision * 100).toStringAsFixed(1)}% '
      '($yes / $scored)');
}

List<String> _parseCsvLine(String line) {
  // Minimal CSV parser: handles quoted fields with embedded commas and "".
  final fields = <String>[];
  var i = 0;
  // Strip BOM on the very first cell if present.
  if (line.isNotEmpty && line.codeUnitAt(0) == 0xFEFF) i = 1;
  while (i <= line.length) {
    if (i < line.length && line[i] == '"') {
      i++;
      final buf = StringBuffer();
      while (i < line.length) {
        if (line[i] == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buf.write('"');
            i += 2;
          } else {
            i++;
            break;
          }
        } else {
          buf.write(line[i]);
          i++;
        }
      }
      fields.add(buf.toString());
      if (i < line.length && line[i] == ',') i++;
    } else {
      final end = line.indexOf(',', i);
      if (end < 0) {
        fields.add(line.substring(i));
        i = line.length + 1;
      } else {
        fields.add(line.substring(i, end));
        i = end + 1;
      }
    }
  }
  return fields;
}
