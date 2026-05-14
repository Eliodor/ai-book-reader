import 'package:ai_book_reader/service/pipeline/discovery/candidate_generator.dart';
import 'package:ai_book_reader/service/pipeline/discovery/cvalue_scorer.dart';
import 'package:ai_book_reader/service/pipeline/discovery/dispersion_scorer.dart';
import 'package:ai_book_reader/service/pipeline/discovery/morphology_clusterer.dart';
import 'package:ai_book_reader/service/pipeline/discovery/raw_models.dart';
import 'package:ai_book_reader/service/pipeline/discovery/substring_penalizer.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_constants.dart';
import 'package:ai_book_reader/service/pipeline/discovery/tokenizer.dart';

/// Input shipped to the discovery [compute] isolate. Everything inside must be
/// either primitive, a List/Map/Set of primitives, or a SendPort — anything
/// that closes over a DB handle / asset bundle is forbidden.
class DiscoveryInput {
  DiscoveryInput({
    required this.chapters,
    required this.sourceLanguage,
    required this.stopwords,
    required this.topN,
  });

  final List<ChapterSnapshot> chapters;
  final String sourceLanguage;
  final Set<String> stopwords;
  final int topN;
}

class DiscoveryOutput {
  DiscoveryOutput({
    required this.candidates,
    required this.occurrences,
    required this.stats,
  });

  final List<CandidatePayload> candidates;
  final List<OccurrencePayload> occurrences;
  final DiscoveryStats stats;
}

class CandidatePayload {
  CandidatePayload({
    required this.sourceText,
    required this.normalizedSource,
    required this.candidateType,
    required this.score,
    required this.frequencyTotal,
    required this.chapterCount,
    required this.firstChapterId,
  });

  final String sourceText;
  final String normalizedSource;
  final String candidateType;
  final double score;
  final int frequencyTotal;
  final int chapterCount;
  final int? firstChapterId;
}

class OccurrencePayload {
  OccurrencePayload({
    required this.normalizedSource,
    required this.chapterId,
    required this.orderIndex,
    required this.position,
    required this.contextBefore,
    required this.contextAfter,
  });

  final String normalizedSource;
  final int chapterId;
  final int orderIndex;
  final int position;
  final String contextBefore;
  final String contextAfter;
}

class DiscoveryStats {
  DiscoveryStats({
    required this.tokenizeMs,
    required this.candidateGenMs,
    required this.cValueMs,
    required this.dispersionMs,
    required this.clusterMs,
    required this.substringMs,
    required this.totalMs,
    required this.rawCandidateCount,
    required this.finalCandidateCount,
  });

  final int tokenizeMs;
  final int candidateGenMs;
  final int cValueMs;
  final int dispersionMs;
  final int clusterMs;
  final int substringMs;
  final int totalMs;
  final int rawCandidateCount;
  final int finalCandidateCount;
}

/// Top-level entry point for `compute(runDiscoveryAll, input)`.
DiscoveryOutput runDiscoveryAll(DiscoveryInput input) {
  final swTotal = Stopwatch()..start();

  // Etap 0 — tokenize all chapters.
  final swTokenize = Stopwatch()..start();
  final tokenized = <TokenizedChapter>[];
  var totalTokens = 0;
  var totalSentences = 0;
  final chapterTokenCounts = <int, int>{};
  for (final ch in input.chapters) {
    final t = tokenize(
      chapterId: ch.id,
      orderIndex: ch.orderIndex,
      content: ch.content,
    );
    tokenized.add(t);
    chapterTokenCounts[ch.id] = t.tokens.length;
    totalTokens += t.tokens.length;
    totalSentences += t.sentenceCount;
  }
  swTokenize.stop();

  // Etap 1 — candidate generation.
  final swGen = Stopwatch()..start();
  final generator = CandidateGenerator(
    sourceLanguage: input.sourceLanguage,
    stopwords: input.stopwords,
  );
  final candidates = generator.run(tokenized);
  swGen.stop();
  final rawCount = candidates.length;

  // Etap 2 — C-value + truncated YAKE.
  final swC = Stopwatch()..start();
  CValueScorer(totalSentences: totalSentences).score(candidates);
  swC.stop();

  // Etap 3 — Gries DP boost.
  final swDp = Stopwatch()..start();
  final chapterCounts = buildChapterCounts(candidates);
  DispersionScorer(
    chapterTokenCounts: chapterTokenCounts,
    totalTokens: totalTokens,
  ).score(candidates, chapterCounts);
  swDp.stop();

  // Etap 4 — morphological clustering (single-pass).
  final swCluster = Stopwatch()..start();
  MorphologyClusterer(sourceLanguage: input.sourceLanguage).cluster(candidates);
  swCluster.stop();

  // Etap 5 — substring containment soft penalty.
  final swSub = Stopwatch()..start();
  applySubstringPenalty(candidates);
  swSub.stop();

  // Etap 6 — sort & cap at topN, build serialisable payloads.
  final ordered = candidates.values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  final limit =
      ordered.length < input.topN ? ordered.length : input.topN;
  final outCandidates = <CandidatePayload>[];
  final outOccurrences = <OccurrencePayload>[];
  for (var i = 0; i < limit; i++) {
    final c = ordered[i];
    outCandidates.add(CandidatePayload(
      sourceText: c.sourceText,
      normalizedSource: c.normalizedSource,
      candidateType: c.candidateType,
      score: c.score,
      frequencyTotal: c.frequencyTotal,
      chapterCount: c.chapterIds.length,
      firstChapterId: c.firstChapterId,
    ));
    for (final occ in c.occurrences) {
      outOccurrences.add(OccurrencePayload(
        normalizedSource: c.normalizedSource,
        chapterId: occ.chapterId,
        orderIndex: occ.orderIndex,
        position: occ.position,
        contextBefore: _trimSnippet(occ.contextBefore),
        contextAfter: _trimSnippet(occ.contextAfter),
      ));
    }
  }

  swTotal.stop();

  return DiscoveryOutput(
    candidates: outCandidates,
    occurrences: outOccurrences,
    stats: DiscoveryStats(
      tokenizeMs: swTokenize.elapsedMilliseconds,
      candidateGenMs: swGen.elapsedMilliseconds,
      cValueMs: swC.elapsedMilliseconds,
      dispersionMs: swDp.elapsedMilliseconds,
      clusterMs: swCluster.elapsedMilliseconds,
      substringMs: swSub.elapsedMilliseconds,
      totalMs: swTotal.elapsedMilliseconds,
      rawCandidateCount: rawCount,
      finalCandidateCount: outCandidates.length,
    ),
  );
}

String _trimSnippet(String s) {
  if (s.length <= occurrenceContextHalfWidth) return s;
  return s.substring(0, occurrenceContextHalfWidth);
}
