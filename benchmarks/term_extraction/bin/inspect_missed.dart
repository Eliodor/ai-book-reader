import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:term_extraction_benchmark/benchmark_metrics.dart';

/// For every ground-truth term that the pipeline missed, show what (if
/// anything) the algorithm DID produce that's textually similar. Helps
/// distinguish "algorithm pruned a real term" from "ground-truth term is an
/// artefact of a too-greedy filter".
///
/// Usage:
///   dart run bin/inspect_missed.dart \
///     --discovery-output=data/solo-leveling/discovery_output.json \
///     [--wiki=solo-leveling] [--mode=strict|loose]
Future<void> main(List<String> args) async {
  String? discoveryPath;
  var wiki = 'solo-leveling';
  var mode = 'loose';
  for (final a in args) {
    if (a.startsWith('--discovery-output=')) {
      discoveryPath = a.substring('--discovery-output='.length);
    } else if (a.startsWith('--wiki=')) {
      wiki = a.substring('--wiki='.length);
    } else if (a.startsWith('--mode=')) {
      mode = a.substring('--mode='.length);
    }
  }
  if (discoveryPath == null) {
    stderr.writeln('--discovery-output=<path> is required.');
    exitCode = 64;
    return;
  }

  final scriptDir = File(Platform.script.toFilePath()).parent.parent;
  final gtFile = File(p.join(scriptDir.path, 'data', wiki, 'ground_truth.json'));
  final gtRaw = jsonDecode(gtFile.readAsStringSync()) as Map<String, dynamic>;
  final cats = gtRaw['categories'] as Map<String, dynamic>;

  final discRaw = jsonDecode(File(discoveryPath).readAsStringSync())
      as Map<String, dynamic>;
  final candidates = (discRaw['candidates'] as List)
      .cast<Map<String, dynamic>>()
      .asMap()
      .entries
      .map((e) => Candidate(
            id: e.key,
            sourceText: e.value['source_text'] as String,
            normalizedSource: e.value['normalized_source'] as String,
            candidateType:
                (e.value['candidate_type'] as String?) ?? 'phrase',
            score: (e.value['score'] as num).toDouble(),
            frequencyTotal: e.value['frequency_total'] as int,
            chapterCount: e.value['chapter_count'] as int,
            status: 'candidate',
          ))
      .toList();

  final matchMode = mode == 'strict' ? MatchMode.strict : MatchMode.loose;

  stdout.writeln('Missed ground-truth terms (mode=$mode):');
  stdout.writeln('-' * 80);
  for (final catEntry in cats.entries) {
    final catName = catEntry.key;
    final pages = (catEntry.value as List).cast<Map<String, dynamic>>();
    final missed = <GtTerm>[];
    for (final page in pages) {
      if (page['canonical_count'] != null) {
        final term = GtTerm(
          category: catName,
          canonical: page['canonical'] as String,
          isEpithet: false,
        );
        final outcome = matchTerm(term, candidates, mode: matchMode);
        if (!outcome.found) missed.add(term);
      }
      final epithets =
          (page['epithets'] as List?)?.cast<Map<String, dynamic>>();
      if (epithets != null) {
        for (final ep in epithets) {
          final term = GtTerm(
            category: catName,
            canonical: ep['text'] as String,
            isEpithet: true,
          );
          final outcome = matchTerm(term, candidates, mode: matchMode);
          if (!outcome.found) missed.add(term);
        }
      }
    }
    if (missed.isEmpty) continue;
    stdout.writeln('\n## $catName (${missed.length} missed)');
    for (final m in missed) {
      final hints = _nearestHints(m.normalized, candidates);
      stdout.writeln('  - ${m.canonical}${m.isEpithet ? " [epithet]" : ""}');
      if (hints.isEmpty) {
        stdout.writeln('      (no similar candidate in top-1500)');
      } else {
        for (final h in hints.take(3)) {
          stdout.writeln('      ~ ${h.sourceText} '
              '(score=${h.score.toStringAsFixed(2)}, '
              'freq=${h.frequencyTotal})');
        }
      }
    }
  }
}

/// Cheap "did the algorithm find anything related" heuristic — any candidate
/// that shares a 4+ character substring with the gt term.
List<Candidate> _nearestHints(String gtNorm, List<Candidate> all) {
  final gtTokens = gtNorm.split(RegExp(r'[\s\-]+'))
      .where((t) => t.length >= 4)
      .toSet();
  if (gtTokens.isEmpty) return const [];
  final scored = <(int, Candidate)>[];
  for (final c in all) {
    final cTokens = c.normalizedForMatch.split(RegExp(r'[\s\-]+')).toSet();
    final shared = gtTokens.intersection(cTokens).length;
    if (shared > 0) scored.add((shared, c));
  }
  scored.sort((a, b) {
    final cmp = b.$1.compareTo(a.$1);
    if (cmp != 0) return cmp;
    return b.$2.score.compareTo(a.$2.score);
  });
  return scored.map((s) => s.$2).toList();
}
