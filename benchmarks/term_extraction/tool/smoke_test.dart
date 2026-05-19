// Sanity test for the benchmark tooling: synthesises a minimal SQLite DB and
// ground_truth.json, then runs the metrics pipeline end-to-end. Catches
// "sqlite3.dll missing" and similar setup issues before they bite during the
// real benchmark.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:term_extraction_benchmark/benchmark_metrics.dart';

void main() {
  stdout.writeln('sqlite3 version: ${sqlite3.version}');

  final root = File(Platform.script.toFilePath()).parent.parent;
  final wikiDir = Directory(p.join(root.path, 'data', '_smoke'))
    ..createSync(recursive: true);
  final dbFile = File(p.join(wikiDir.path, 'smoke.db'));
  if (dbFile.existsSync()) dbFile.deleteSync();

  final db = sqlite3.open(dbFile.path);
  db.execute('''
    CREATE TABLE tb_term_candidates (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      book_id INTEGER NOT NULL,
      source_text TEXT NOT NULL,
      normalized_source TEXT NOT NULL,
      candidate_type TEXT NOT NULL DEFAULT 'phrase',
      score REAL NOT NULL DEFAULT 0,
      frequency_total INTEGER NOT NULL DEFAULT 0,
      chapter_count INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'candidate'
    )
  ''');
  final fakeCandidates = <List<Object?>>[
    [1, 'Sung Jinwoo', 'sung jinwoo', 'proper_name', 2.5, 543, 18, 'accepted'],
    [1, 'Jinwoo', 'jinwoo', 'proper_name', 1.8, 1024, 19, 'accepted'],
    [1, 'Igris', 'igris', 'proper_name', 1.2, 87, 12, 'accepted'],
    [1, 'Shadow Monarch', 'shadow monarch', 'phrase', 1.5, 41, 8, 'accepted'],
    [1, 'random noise', 'random noise', 'phrase', 0.3, 5, 2, 'rejected'],
  ];
  final stmt = db.prepare('''
    INSERT INTO tb_term_candidates
    (book_id, source_text, normalized_source, candidate_type, score,
     frequency_total, chapter_count, status)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  ''');
  for (final row in fakeCandidates) {
    stmt.execute(row);
  }
  stmt.dispose();

  final candidateRows = db.select('SELECT * FROM tb_term_candidates');
  stdout.writeln('Inserted ${candidateRows.length} fake candidates.');
  db.dispose();

  // Synthesise a ground_truth.json matching the filter_by_text output shape.
  final gt = {
    'wiki': '_smoke',
    'book': 'fake.epub',
    'filtered_at': DateTime.now().toUtc().toIso8601String(),
    'min_count': 1,
    'stats': const <String, Map<String, int>>{},
    'categories': {
      'Characters': [
        {'canonical': 'Sung Jinwoo', 'canonical_count': 543},
        {'canonical': 'Cha Hae-In', 'canonical_count': 200},
      ],
      'Shadows': [
        {'canonical': 'Igris', 'canonical_count': 87},
      ],
      'Titles': [
        {'canonical': 'Shadow Monarch', 'canonical_count': 41},
        {'canonical': 'Knight of Death', 'canonical_count': 5},
      ],
    },
  };
  File(p.join(wikiDir.path, 'ground_truth.json')).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(gt),
  );

  // Call metrics on the synthetic data so the algorithm runs at least once.
  final terms = <GtTerm>[
    GtTerm(category: 'Characters', canonical: 'Sung Jinwoo', isEpithet: false),
    GtTerm(category: 'Characters', canonical: 'Cha Hae-In', isEpithet: false),
    GtTerm(category: 'Shadows', canonical: 'Igris', isEpithet: false),
    GtTerm(category: 'Titles', canonical: 'Shadow Monarch', isEpithet: true),
    GtTerm(category: 'Titles', canonical: 'Knight of Death', isEpithet: true),
  ];
  final candidates = <Candidate>[
    for (final row in fakeCandidates)
      Candidate(
        id: 0,
        sourceText: row[1]! as String,
        normalizedSource: row[2]! as String,
        candidateType: row[3]! as String,
        score: (row[4]! as num).toDouble(),
        frequencyTotal: row[5]! as int,
        chapterCount: row[6]! as int,
        status: row[7]! as String,
      ),
  ];
  final rows = computeRecallByCategory(terms, candidates);
  stdout.writeln('Synthetic recall:');
  for (final r in rows) {
    stdout.writeln('  ${r.category.padRight(12)} '
        'terms=${r.terms} strict=${r.foundStrict} loose=${r.foundLoose}');
  }

  stdout.writeln('');
  stdout.writeln('Now invoke the real script against the smoke DB:');
  stdout.writeln('  dart run bin/run_benchmark.dart \\');
  stdout.writeln('    --db ${dbFile.path} --book-id 1 --wiki _smoke');
}
