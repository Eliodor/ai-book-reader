// One-shot: reads data/solo-leveling/cache/terms/volume_NN_terms.json (8 files,
// flat string arrays produced by parallel extractor agents) and merges them
// into one deduplicated, sorted JSON array at
// data/solo-leveling/extracted_terms.json.
//
// Dedup is exact-string (case-sensitive, whitespace-trimmed). No category
// grouping, no metadata.
//
// Run with:
//   dart run tool/merge_volume_terms.dart

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

void main() {
  final root = File(Platform.script.toFilePath()).parent.parent;
  final termsDir = Directory(
      p.join(root.path, 'data', 'solo-leveling', 'cache', 'terms'));
  if (!termsDir.existsSync()) {
    stderr.writeln('Terms cache dir not found: ${termsDir.path}');
    exitCode = 1;
    return;
  }

  final files = termsDir
      .listSync()
      .whereType<File>()
      .where((f) => p.extension(f.path).toLowerCase() == '.json')
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  if (files.isEmpty) {
    stderr.writeln('No volume term files in ${termsDir.path}');
    exitCode = 1;
    return;
  }

  final perVolume = <String, int>{};
  final merged = <String>{};
  for (final f in files) {
    final raw = f.readAsStringSync();
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      stderr.writeln('Skipping ${f.path}: not a JSON array');
      continue;
    }
    var count = 0;
    for (final item in decoded) {
      if (item is! String) continue;
      final term = item.trim();
      if (term.isEmpty) continue;
      merged.add(term);
      count += 1;
    }
    perVolume[p.basename(f.path)] = count;
  }

  final sorted = merged.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  final outFile = File(
      p.join(root.path, 'data', 'solo-leveling', 'extracted_terms.json'));
  outFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(sorted) + '\n');

  stdout.writeln('Per-volume raw counts:');
  var rawTotal = 0;
  for (final entry in perVolume.entries) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
    rawTotal += entry.value;
  }
  stdout.writeln('Raw total:        $rawTotal');
  stdout.writeln('Unique terms:     ${sorted.length}');
  stdout.writeln('Wrote:            ${outFile.path}');
}
