// One-shot: reads data/solo-leveling/extracted_terms.json (deduped flat array)
// and writes data/solo-leveling/extracted_terms_normalized.json with
// case/hyphen + conservative plural folding applied. The shared normaliser
// lives in lib/term_normalizer.dart so Stage A and LLM glossaries fold
// identically.
//
// Run with:
//   dart run tool/normalize_terms.dart

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:term_extraction_benchmark/term_normalizer.dart';

void main() {
  final root = File(Platform.script.toFilePath()).parent.parent;
  final inFile = File(
      p.join(root.path, 'data', 'solo-leveling', 'extracted_terms.json'));
  if (!inFile.existsSync()) {
    stderr.writeln('Input not found: ${inFile.path}');
    exitCode = 1;
    return;
  }

  final terms =
      (jsonDecode(inFile.readAsStringSync()) as List).cast<String>();

  final canonicalToVariants = normalizeTerms(terms);
  final canonicalList = canonicalToVariants.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  final outFile = File(p.join(
      root.path, 'data', 'solo-leveling', 'extracted_terms_normalized.json'));
  outFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(canonicalList) + '\n');

  final groupsFile = File(p.join(
      root.path, 'data', 'solo-leveling', 'extracted_terms_groups.json'));
  final groupsOut = canonicalList
      .map((c) => {'canonical': c, 'variants': canonicalToVariants[c]})
      .toList();
  groupsFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(groupsOut) + '\n');

  final mergedCount =
      canonicalToVariants.values.where((v) => v.length > 1).length;
  stdout.writeln('Input terms:             ${terms.length}');
  stdout.writeln('After normalisation:     ${canonicalList.length}');
  stdout.writeln('Groups with >1 variant:  $mergedCount');
  stdout.writeln('');
  stdout.writeln('Wrote: ${outFile.path}');
  stdout.writeln('Wrote: ${groupsFile.path}');
}
