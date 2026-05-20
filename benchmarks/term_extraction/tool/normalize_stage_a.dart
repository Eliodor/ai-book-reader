// One-shot: reads data/solo-leveling/discovery_output.json (Stage A output,
// {candidates: [{source_text, ...}, ...]}) and writes
// data/solo-leveling/stage_a_normalized.json + stage_a_groups.json with the
// same case/hyphen + conservative plural folding as the LLM glossary.
//
// Purpose: lets us re-run the benchmark on a normalised Stage A pool and see
// how much of the 23 p.p. LLM lead is just LLM picking better canonical forms
// vs Stage A surfacing all the variants but never collapsing them.
//
// Run with:
//   dart run tool/normalize_stage_a.dart

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:term_extraction_benchmark/term_normalizer.dart';

void main() {
  final root = File(Platform.script.toFilePath()).parent.parent;
  final inFile = File(
      p.join(root.path, 'data', 'solo-leveling', 'discovery_output.json'));
  if (!inFile.existsSync()) {
    stderr.writeln('Input not found: ${inFile.path}');
    exitCode = 1;
    return;
  }

  final raw =
      jsonDecode(inFile.readAsStringSync()) as Map<String, dynamic>;
  final candidates = (raw['candidates'] as List).cast<Map<String, dynamic>>();
  final terms = <String>[];
  for (final c in candidates) {
    final t = (c['source_text'] as String?)?.trim() ?? '';
    if (t.isNotEmpty) terms.add(t);
  }

  final canonicalToVariants = normalizeTerms(terms);
  final canonicalList = canonicalToVariants.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  final outFile = File(
      p.join(root.path, 'data', 'solo-leveling', 'stage_a_normalized.json'));
  outFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(canonicalList) + '\n');

  final groupsFile = File(
      p.join(root.path, 'data', 'solo-leveling', 'stage_a_groups.json'));
  final groupsOut = canonicalList
      .map((c) => {'canonical': c, 'variants': canonicalToVariants[c]})
      .toList();
  groupsFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(groupsOut) + '\n');

  final mergedCount =
      canonicalToVariants.values.where((v) => v.length > 1).length;
  stdout.writeln('Stage A candidates:      ${terms.length}');
  stdout.writeln('After normalisation:     ${canonicalList.length}');
  stdout.writeln('Groups with >1 variant:  $mergedCount');
  stdout.writeln('');
  stdout.writeln('Sample merged groups (top 15 by variant count):');
  final samples = canonicalToVariants.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  for (final e in samples.take(15)) {
    if (e.value.length < 2) break;
    stdout.writeln('  ${e.key}  <-  ${e.value.join(" | ")}');
  }
  stdout.writeln('');
  stdout.writeln('Wrote: ${outFile.path}');
  stdout.writeln('Wrote: ${groupsFile.path}');
}
