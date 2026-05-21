import 'dart:async';
import 'dart:isolate';

import 'package:ai_book_reader/service/pipeline/discovery/candidate_generator.dart';
import 'package:ai_book_reader/service/pipeline/discovery/cvalue_scorer.dart';
import 'package:ai_book_reader/service/pipeline/discovery/dispersion_scorer.dart';
import 'package:ai_book_reader/service/pipeline/discovery/morphology_clusterer.dart';
import 'package:ai_book_reader/service/pipeline/discovery/raw_models.dart';
import 'package:ai_book_reader/service/pipeline/discovery/substring_penalizer.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_constants.dart';
import 'package:ai_book_reader/service/pipeline/discovery/tokenizer.dart';

/// Input shipped to the discovery isolate. Everything inside must be either
/// primitive, a List/Map/Set of primitives, or a SendPort — anything that
/// closes over a DB handle / asset bundle is forbidden.
class DiscoveryInput {
  DiscoveryInput({
    required this.chapters,
    required this.sourceLanguage,
    required this.stopwords,
    required this.topN,
    this.minScore = 0.0,
  });

  final List<ChapterSnapshot> chapters;
  final String sourceLanguage;
  final Set<String> stopwords;

  /// Hard upper bound on the number of candidates persisted, regardless of
  /// score. Acts as a safety net so a pathological book can't push hundreds
  /// of thousands of candidates downstream.
  final int topN;

  /// Lower bound on the candidate score. Anything at or below this is dropped
  /// before persistence. The default of 0 trims the score=0 tail (substring
  /// penalty collapses pure duplicates to zero; nothing of value sits there).
  final double minScore;
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
    required this.prefilterMs,
    required this.cValueMs,
    required this.clusterMs,
    required this.dispersionMs,
    required this.substringMs,
    required this.totalMs,
    required this.rawCandidateCount,
    required this.prefilteredCount,
    required this.finalCandidateCount,
  });

  final int tokenizeMs;
  final int candidateGenMs;
  final int prefilterMs;
  final int cValueMs;
  final int clusterMs;
  final int dispersionMs;
  final int substringMs;
  final int totalMs;
  final int rawCandidateCount;
  final int prefilteredCount;
  final int finalCandidateCount;
}

/// Cap applied after the low-frequency prefilter. Above this the C-value
/// pairwise substring scan still degrades to seconds even after pruning, so we
/// keep the top-N by raw frequency as a safety net.
const int _maxCandidatesAfterPrefilter = 20000;

/// Arguments passed to [discoveryIsolateEntry] via `Isolate.spawn`.
class DiscoverySpawnArgs {
  DiscoverySpawnArgs({
    required this.mainSendPort,
    required this.input,
  });

  final SendPort mainSendPort;
  final DiscoveryInput input;
}

/// Marker sent by the worker on its main port immediately after it has set up
/// its own [ReceivePort]. Lets the orchestrator know which port to use for
/// cancellation signals.
class DiscoveryIsolateReady {
  DiscoveryIsolateReady(this.cancelPort);
  final SendPort cancelPort;
}

class DiscoveryIsolateResult {
  DiscoveryIsolateResult(this.output);
  final DiscoveryOutput output;
}

class DiscoveryIsolateError {
  DiscoveryIsolateError(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}

/// Sentinel value the orchestrator sends to the worker's cancel port.
const String discoveryCancelSignal = 'discovery_cancel';

/// Sentinel emitted by the worker after honouring a cancellation.
const String discoveryCancelledResult = 'discovery_cancelled';

/// Internal exception thrown from inside the pipeline once a cancellation is
/// observed at a yield point.
class _DiscoveryCancelledException implements Exception {
  const _DiscoveryCancelledException();
}

/// Isolate entry — spawned via `Isolate.spawn(discoveryIsolateEntry, args)`.
///
/// Listens on its own [ReceivePort] for a cancel sentinel and runs the async
/// pipeline. Yields back to the event loop frequently enough that the cancel
/// message is observed within a few hundred milliseconds.
Future<void> discoveryIsolateEntry(DiscoverySpawnArgs args) async {
  final main = args.mainSendPort;
  final cancelPort = ReceivePort();
  var cancelled = false;
  final sub = cancelPort.listen((msg) {
    if (msg == discoveryCancelSignal) cancelled = true;
  });

  main.send(DiscoveryIsolateReady(cancelPort.sendPort));

  try {
    final output = await _runDiscoveryAsync(args.input, () => cancelled);
    if (cancelled) {
      main.send(discoveryCancelledResult);
    } else {
      main.send(DiscoveryIsolateResult(output));
    }
  } on _DiscoveryCancelledException {
    main.send(discoveryCancelledResult);
  } catch (e, st) {
    main.send(DiscoveryIsolateError(e, st));
  } finally {
    await sub.cancel();
    cancelPort.close();
  }
}

/// The heart of Stage A. Same six etaps as before, but reordered (cluster
/// before dispersion — see term_extraction_fixes.md Fix 6) and gated by a
/// cancellation token that the caller checks via [isCancelled].
Future<DiscoveryOutput> _runDiscoveryAsync(
  DiscoveryInput input,
  bool Function() isCancelled,
) async {
  final swTotal = Stopwatch()..start();

  Future<void> yieldCheck() async {
    await Future<void>.delayed(Duration.zero);
    if (isCancelled()) throw const _DiscoveryCancelledException();
  }

  // Etap 0 — tokenize all chapters.
  await yieldCheck();
  final swTokenize = Stopwatch()..start();
  final tokenized = <TokenizedChapter>[];
  var totalTokens = 0;
  var totalSentences = 0;
  final chapterTokenCounts = <int, int>{};
  for (final ch in input.chapters) {
    if (isCancelled()) throw const _DiscoveryCancelledException();
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
  await yieldCheck();
  final swGen = Stopwatch()..start();
  final generator = CandidateGenerator(
    sourceLanguage: input.sourceLanguage,
    stopwords: input.stopwords,
  );
  final candidates = generator.run(tokenized);
  swGen.stop();
  final rawCount = candidates.length;

  // Etap 1.3 — heuristic junk filter. Drops fleeting one-chapter low-frequency
  // mentions and phrases of 5+ words *before* C-value runs (C-value is O(K²)
  // over the pool size, so eliminating obvious noise here is the biggest
  // single performance lever in Stage A). Stage B then sees only candidates
  // that have at least passed structural checks — saves a large fraction of
  // its LLM budget. See heuristicJunkSingleChapterMaxFreq /
  // heuristicJunkLongPhraseWordCount in term_discovery_constants.dart.
  await yieldCheck();
  _heuristicJunkFilter(candidates);

  // Etap 1.5 — pre-filter low-frequency candidates so the O(K^2) C-value scan
  // doesn't explode on books that yield 50k+ raw candidates. See Fix 3 in
  // term_extraction_fixes.md.
  await yieldCheck();
  final swPrefilter = Stopwatch()..start();
  _prefilterCandidates(candidates);
  swPrefilter.stop();
  final prefilteredCount = candidates.length;

  // Etap 2 — C-value + truncated YAKE.
  await yieldCheck();
  final swC = Stopwatch()..start();
  await CValueScorer(totalSentences: totalSentences)
      .score(candidates, isCancelled: isCancelled);
  swC.stop();

  // Etap 3 — morphological clustering (single-pass). Seeds with C-value ×
  // YAKE features only; DP boost runs *after* clustering so it operates on
  // cluster representatives rather than getting diluted across surface forms.
  await yieldCheck();
  final swCluster = Stopwatch()..start();
  MorphologyClusterer(sourceLanguage: input.sourceLanguage).cluster(candidates);
  swCluster.stop();

  // Etap 4 — Gries DP boost on cluster representatives. Reads per-chapter
  // frequencies from each candidate's own chapterFrequencies map (populated
  // exactly during generation, merged across morphological variants).
  // Also runs the early-chapter recency bonus inside the same pass.
  await yieldCheck();
  final swDp = Stopwatch()..start();
  final earlyChapterCount = (input.chapters.length / 3).ceil();
  final earlyChapterIds = <int>{};
  for (final ch in input.chapters) {
    if (ch.orderIndex < earlyChapterCount) {
      earlyChapterIds.add(ch.id);
    }
  }
  DispersionScorer(
    chapterTokenCounts: chapterTokenCounts,
    totalTokens: totalTokens,
    earlyChapterIds: earlyChapterIds,
  ).score(candidates);
  swDp.stop();

  // Etap 5 — substring containment soft penalty.
  await yieldCheck();
  final swSub = Stopwatch()..start();
  applySubstringPenalty(candidates);
  swSub.stop();

  // Etap 6 — sort, then cut where the score crosses the floor; topN is a
  // safety cap on top of that. Ordering is descending, so the first
  // candidate with score <= minScore tells us where the tail of zero-value
  // entries begins.
  await yieldCheck();
  final ordered = candidates.values.toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  var limit =
      ordered.length < input.topN ? ordered.length : input.topN;
  for (var i = 0; i < limit; i++) {
    if (ordered[i].score <= input.minScore) {
      limit = i;
      break;
    }
  }
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
      prefilterMs: swPrefilter.elapsedMilliseconds,
      cValueMs: swC.elapsedMilliseconds,
      clusterMs: swCluster.elapsedMilliseconds,
      dispersionMs: swDp.elapsedMilliseconds,
      substringMs: swSub.elapsedMilliseconds,
      totalMs: swTotal.elapsedMilliseconds,
      rawCandidateCount: rawCount,
      prefilteredCount: prefilteredCount,
      finalCandidateCount: outCandidates.length,
    ),
  );
}

/// Drops candidates that are structurally unlikely to be glossary terms:
///   - **single-word** one-chapter fleeting mentions: `wordCount == 1` AND
///     `chapter_count == 1` AND
///     `frequency_total <= heuristicJunkSingleChapterMaxFreq`. Catches
///     ALL-CAPS abbreviations (`Atm`, `Sos`, `Hp Hp`), onomatopoeia
///     (`Rrrummble`), and generic words that happened to land sentence-
///     initial just once (`Friendship`, `Boss`). Multi-word fleeting
///     candidates are preserved — they're more likely to be real proper
///     nouns (e.g. `Dungeon Jackals`, `Penalty Zone`) than noise.
///   - **long phrases**: total word count >= `heuristicJunkLongPhraseWordCount`
///     (counting connectors, unlike `RawCandidate.wordCount`). Dialogue and
///     System sentences that slipped through the chain assembler.
///
/// Runs *before* C-value because C-value is O(K²) over the pool size; cutting
/// the noise floor here is the single biggest performance lever in Stage A.
void _heuristicJunkFilter(Map<String, RawCandidate> candidates) {
  if (candidates.isEmpty) return;
  candidates.removeWhere((_, c) {
    if (c.chapterIds.length == 1 &&
        c.frequencyTotal <= heuristicJunkSingleChapterMaxFreq) {
      return true;
    }
    final totalWords = c.normalizedSource.split(' ').length;
    if (totalWords >= heuristicJunkLongPhraseWordCount) return true;
    return false;
  });
}

/// Drops single-word hapax legomena (`wordCount==1 && frequencyTotal<2`) and,
/// if the pool is still huge, keeps only the top [_maxCandidatesAfterPrefilter]
/// by raw frequency. Multi-word candidates are preserved unconditionally —
/// rare unique multi-word strings are usually meaningful proper names.
void _prefilterCandidates(Map<String, RawCandidate> candidates) {
  if (candidates.isEmpty) return;
  final keys = candidates.keys.toList(growable: false);
  for (final key in keys) {
    final c = candidates[key];
    if (c == null) continue;
    if (c.wordCount <= 1 && c.frequencyTotal < 2) {
      candidates.remove(key);
    }
  }
  if (candidates.length > _maxCandidatesAfterPrefilter) {
    final sorted = candidates.values.toList()
      ..sort((a, b) => b.frequencyTotal.compareTo(a.frequencyTotal));
    candidates.clear();
    for (var i = 0; i < _maxCandidatesAfterPrefilter; i++) {
      final c = sorted[i];
      candidates[c.normalizedSource] = c;
    }
  }
}

String _trimSnippet(String s) {
  if (s.length <= occurrenceContextHalfWidth) return s;
  return s.substring(0, occurrenceContextHalfWidth);
}
