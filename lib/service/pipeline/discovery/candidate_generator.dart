import 'package:ai_book_reader/service/pipeline/discovery/raw_models.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_constants.dart';
import 'package:ai_book_reader/service/pipeline/discovery/tokenizer.dart';

/// Stage 1 of discovery — turn a sequence of tokenised chapters into a flat
/// dictionary of [RawCandidate]s keyed by `normalizedSource`.
///
/// The strategy is capitalisation-driven with three extra channels:
/// - **multi-word groups** of consecutive capitalised tokens with optional
///   language-specific connectors,
/// - **quoted phrases** (translator-marked terms),
/// - **in-text n-grams** for non-Latin scripts (Chinese, Korean, Japanese)
///   where capitalisation is not a signal.
///
/// Pure function — safe to call inside an Isolate. No DB / FS access.
class CandidateGenerator {
  CandidateGenerator({
    required this.sourceLanguage,
    required this.stopwords,
    Map<String, List<String>>? connectorsByLang,
  }) : connectors = (connectorsByLang ?? connectorsByLanguage)[sourceLanguage]
                ?.map((c) => c.toLowerCase())
                .toSet() ??
            <String>{};

  final String sourceLanguage;
  final Set<String> stopwords;
  final Set<String> connectors;

  /// Map from `normalized_source` to the running candidate.
  final Map<String, RawCandidate> _candidates = <String, RawCandidate>{};

  /// Map normalized → count of usages where the token was sentence-initial.
  final Map<String, int> _sentenceInitialCounts = <String, int>{};

  /// Map normalized → count of usages mid-sentence. Used to decide if a
  /// sentence-initial occurrence of "Master" is legitimate (it appears
  /// capitalised mid-sentence elsewhere too) vs. spurious.
  final Map<String, int> _midSentenceCounts = <String, int>{};

  /// Counts ALL CAPS form occurrences keyed by normalised text.
  final Map<String, int> _allCapsCounts = <String, int>{};

  /// First pass: pre-compute mid-sentence vs. sentence-initial counts so we
  /// know which sentence-initial capitalisations to trust.
  void _prepass(List<TokenizedChapter> chapters) {
    for (final ch in chapters) {
      for (final tok in ch.tokens) {
        if (!tok.isCapitalized) continue;
        final key = tok.normalizedText;
        if (tok.isSentenceInitial) {
          _sentenceInitialCounts[key] =
              (_sentenceInitialCounts[key] ?? 0) + 1;
        } else {
          _midSentenceCounts[key] = (_midSentenceCounts[key] ?? 0) + 1;
        }
        if (tok.isAllCaps) {
          _allCapsCounts[key] = (_allCapsCounts[key] ?? 0) + 1;
        }
      }
    }
  }

  /// Should we trust a sentence-initial capitalised token? Yes if the same
  /// token occurs capitalised mid-sentence at least once elsewhere, OR if it
  /// recurs as sentence-initial often enough to be a name in its own right
  /// (e.g. "Aragorn drew his sword. Aragorn turned. Aragorn looked.").
  bool _trustToken(Token tok) {
    if (!tok.isCapitalized) return false;
    if (!tok.isSentenceInitial) return true;
    final mid = _midSentenceCounts[tok.normalizedText] ?? 0;
    if (mid > 0) return true;
    final initial = _sentenceInitialCounts[tok.normalizedText] ?? 0;
    return initial >= _sentenceInitialTrustThreshold;
  }

  static const int _sentenceInitialTrustThreshold = 3;

  /// Build candidates from one tokenised chapter. The instance accumulates
  /// state across all chapters — call once per chapter, then [finalize].
  void ingestChapter(TokenizedChapter chapter, String normalizedContent) {
    final tokens = chapter.tokens;
    var i = 0;
    while (i < tokens.length) {
      final tok = tokens[i];
      if (!_trustToken(tok)) {
        i++;
        continue;
      }

      // Greedy walk: grow the group while next token is capitalised, or is
      // a connector sandwiched between capitalised tokens.
      final groupEnd = _walkGroupEnd(tokens, i);
      if (groupEnd > i) {
        // Try each sub-group of length 1..(groupEnd - i + 1) ≤ max.
        _emitGroup(tokens, i, groupEnd, chapter, normalizedContent);
      } else {
        // Single capitalised token — emit as length-1 candidate.
        _emitSingle(tokens, i, chapter, normalizedContent);
      }
      i = groupEnd + 1;
    }

    _ingestQuotedSpans(chapter, normalizedContent);
  }

  /// Returns the index of the last token in a capitalised group starting at
  /// [start], obeying [maxCandidateWordCount] (counted in content words —
  /// connectors are free) and the connector-chain rule (up to
  /// [_maxConnectorChain] consecutive connectors are bridged when followed by
  /// another trusted capitalised token).
  int _walkGroupEnd(List<Token> tokens, int start) {
    var end = start;
    var j = start + 1;
    var contentWords = 1;
    while (j < tokens.length && contentWords < maxCandidateWordCount) {
      final candidate = tokens[j];
      if (candidate.isCapitalized && _trustToken(candidate)) {
        end = j;
        j++;
        contentWords++;
        continue;
      }
      if (connectors.contains(candidate.normalizedText)) {
        // Skip up to _maxConnectorChain consecutive connectors and require a
        // trusted capitalised token afterwards.
        var k = j;
        var connectorCount = 0;
        while (k < tokens.length &&
            connectorCount < _maxConnectorChain &&
            connectors.contains(tokens[k].normalizedText)) {
          k++;
          connectorCount++;
        }
        if (k < tokens.length &&
            tokens[k].isCapitalized &&
            _trustToken(tokens[k])) {
          end = k;
          j = k + 1;
          contentWords++; // connectors do not consume the word-count budget.
          continue;
        }
      }
      break;
    }
    return end;
  }

  static const int _maxConnectorChain = 3;

  void _emitGroup(
    List<Token> tokens,
    int start,
    int end,
    TokenizedChapter chapter,
    String normalizedContent,
  ) {
    // Emit every contiguous sub-span (from, to) inside [start..end]. Spans
    // that start or end with a connector are skipped — they are filtered out
    // anyway by [_emitSpan]'s boundary check, but skipping here avoids the
    // allocation. The number of content words (non-connectors) is capped at
    // [maxCandidateWordCount]. For a length-5 group this is at most ~15
    // emissions.
    for (var from = start; from <= end; from++) {
      if (connectors.contains(tokens[from].normalizedText)) continue;
      var contentWords = 0;
      for (var to = from; to <= end; to++) {
        final isConn = connectors.contains(tokens[to].normalizedText);
        if (!isConn) {
          contentWords++;
          if (contentWords > maxCandidateWordCount) break;
          _emitSpan(tokens, from, to, chapter, normalizedContent);
        }
      }
    }
  }

  void _emitSingle(
    List<Token> tokens,
    int idx,
    TokenizedChapter chapter,
    String normalizedContent,
  ) {
    _emitSpan(tokens, idx, idx, chapter, normalizedContent);
  }

  void _emitSpan(
    List<Token> tokens,
    int start,
    int end,
    TokenizedChapter chapter,
    String normalizedContent,
  ) {
    // Build the display text (Title Case from individual tokens) and the
    // normalised key (lower-case, single space).
    final parts = <String>[];
    final normalizedParts = <String>[];
    var allCaps = true;
    for (var i = start; i <= end; i++) {
      final tok = tokens[i];
      parts.add(_titleCase(tok.text));
      normalizedParts.add(tok.normalizedText);
      if (!tok.isAllCaps) allCaps = false;
    }
    final sourceText = parts.join(' ');
    final normalized = normalizedParts.join(' ').trim();
    if (normalized.isEmpty) return;

    // Boundary trim: never start or end with a stopword / connector / article.
    final firstNorm = normalizedParts.first;
    final lastNorm = normalizedParts.last;
    if (stopwords.contains(firstNorm) ||
        stopwords.contains(lastNorm) ||
        connectors.contains(firstNorm) ||
        connectors.contains(lastNorm) ||
        universalArticles.contains(firstNorm) ||
        universalArticles.contains(lastNorm)) {
      return;
    }
    if (parts.length == 1 && parts.first.length < 3) return;

    // Content-word count for C-value: connectors (of/the/de/von/…) are not
    // counted, so "Master of Crimson" gets wordCount=2, not 3.
    var contentWordCount = 0;
    for (final np in normalizedParts) {
      if (!connectors.contains(np)) contentWordCount++;
    }
    if (contentWordCount == 0) return;

    final type = _classify(normalized, contentWordCount);
    final cand = _candidates.putIfAbsent(
      normalized,
      () => RawCandidate(
        sourceText: sourceText,
        normalizedSource: normalized,
        candidateType: type,
        wordCount: contentWordCount,
      ),
    );
    cand.frequencyTotal++;
    cand.chapterIds.add(chapter.chapterId);
    cand.chapterFrequencies.update(
      chapter.chapterId,
      (v) => v + 1,
      ifAbsent: () => 1,
    );
    cand.firstChapterId ??= chapter.chapterId;
    if (allCaps) cand.allCapsOccurrences++;
    final sentenceKey =
        chapter.orderIndex * 1000000 + tokens[start].sentenceIndex;
    cand.uniqueSentences.add(sentenceKey);

    if (cand.occurrences.length < maxOccurrencesPerCandidate) {
      final position = tokens[start].start;
      final endChar = tokens[end].end;
      cand.occurrences.add(RawOccurrence(
        chapterId: chapter.chapterId,
        orderIndex: chapter.orderIndex,
        position: position,
        sentenceIndex: tokens[start].sentenceIndex,
        contextBefore: _contextBefore(normalizedContent, position),
        contextAfter: _contextAfter(normalizedContent, endChar),
        isAllCapsForm: allCaps,
      ));
    }
  }

  static final RegExp _quotedPattern = RegExp(
    r'[“"„«]([^”"’«»]{3,40})[”"’»]',
    unicode: true,
  );

  void _ingestQuotedSpans(
    TokenizedChapter chapter,
    String normalizedContent,
  ) {
    for (final match in _quotedPattern.allMatches(normalizedContent)) {
      final raw = match.group(1)?.trim();
      if (raw == null || raw.isEmpty) continue;
      final normalized = _collapseWhitespace(raw.toLowerCase());
      if (normalized.length < 3) continue;
      if (stopwords.contains(normalized)) continue;

      final words = normalized.split(' ');
      if (words.length > maxCandidateWordCount) continue;
      if (words.any((w) => w.isEmpty)) continue;

      final cand = _candidates.putIfAbsent(
        normalized,
        () => RawCandidate(
          sourceText: raw,
          normalizedSource: normalized,
          candidateType: 'phrase',
          wordCount: words.length,
        ),
      );
      cand.frequencyTotal++;
      cand.chapterIds.add(chapter.chapterId);
      cand.chapterFrequencies.update(
        chapter.chapterId,
        (v) => v + 1,
        ifAbsent: () => 1,
      );
      cand.firstChapterId ??= chapter.chapterId;
      final sentenceKey = chapter.orderIndex * 1000000;
      cand.uniqueSentences.add(sentenceKey);
      if (cand.occurrences.length < maxOccurrencesPerCandidate) {
        final position = match.start;
        final endChar = match.end;
        cand.occurrences.add(RawOccurrence(
          chapterId: chapter.chapterId,
          orderIndex: chapter.orderIndex,
          position: position,
          sentenceIndex: 0,
          contextBefore: _contextBefore(normalizedContent, position),
          contextAfter: _contextAfter(normalizedContent, endChar),
        ));
      }
    }
  }

  /// In-text n-gram channel for non-Latin scripts. Activate only if the source
  /// language is Chinese/Japanese/Korean — there capitalisation gives nothing.
  void ingestNonLatinNgrams(List<TokenizedChapter> chapters) {
    if (!_isNonLatinScript(sourceLanguage)) return;
    // Map normalised n-gram -> (frequency, chapter set, sample chapter).
    final counter = <String, _NgramCounter>{};
    for (final ch in chapters) {
      for (var i = 0; i < ch.tokens.length; i++) {
        for (var n = 1; n <= 3; n++) {
          if (i + n > ch.tokens.length) break;
          final slice = ch.tokens.sublist(i, i + n);
          if (slice.any((t) => stopwords.contains(t.normalizedText))) continue;
          final norm = slice.map((t) => t.normalizedText).join(' ');
          if (norm.length < 2) continue;
          final c = counter.putIfAbsent(
            norm,
            () => _NgramCounter(
              sourceText: slice.map((t) => t.text).join(' '),
              firstChapterId: ch.chapterId,
              orderIndex: ch.orderIndex,
              firstPosition: slice.first.start,
            ),
          );
          c.frequency++;
          c.chapterIds.add(ch.chapterId);
          c.chapterFrequencies.update(
            ch.chapterId,
            (v) => v + 1,
            ifAbsent: () => 1,
          );
        }
      }
    }
    counter.forEach((norm, c) {
      if (c.frequency < ngramMinFrequency) return;
      if (c.chapterIds.length < ngramMinChapterCount) return;
      final cand = _candidates.putIfAbsent(
        norm,
        () => RawCandidate(
          sourceText: c.sourceText,
          normalizedSource: norm,
          candidateType: 'phrase',
          wordCount: norm.split(' ').length,
        ),
      );
      cand.frequencyTotal += c.frequency;
      cand.chapterIds.addAll(c.chapterIds);
      c.chapterFrequencies.forEach((chId, count) {
        cand.chapterFrequencies.update(
          chId,
          (v) => v + count,
          ifAbsent: () => count,
        );
      });
      cand.firstChapterId ??= c.firstChapterId;
    });
  }

  Map<String, RawCandidate> finalize() {
    for (final c in _candidates.values) {
      // chapter count is the size of the chapter set.
      // chapterCount stored explicitly on the model later; here we leave
      // chapterIds as authoritative.
      c.firstChapterId ??= c.chapterIds.isEmpty ? null : c.chapterIds.first;
    }
    return _candidates;
  }

  /// Convenience: ingest a whole book in one call.
  Map<String, RawCandidate> run(List<TokenizedChapter> chapters) {
    _prepass(chapters);
    for (final ch in chapters) {
      ingestChapter(ch, ch.normalizedContent);
    }
    ingestNonLatinNgrams(chapters);
    return finalize();
  }

  static String _titleCase(String text) {
    if (text.isEmpty) return text;
    final first = text.substring(0, 1).toUpperCase();
    final rest = text.substring(1).toLowerCase();
    return first + rest;
  }

  String _classify(String normalized, int wordCount) {
    // Cheap heuristic — Stage B re-classifies. Picks "title", "organization",
    // "technique" if the last token matches a known suffix; otherwise
    // "proper_name" for short multi-word, "phrase" for longer.
    final words = normalized.split(' ');
    final last = words.isEmpty ? '' : words.last;
    if (_orgSuffixes.contains(last)) return 'organization';
    if (_techSuffixes.contains(last)) return 'technique';
    if (_titlePrefixes.contains(words.first)) return 'title';
    if (wordCount == 1) return 'proper_name';
    if (wordCount <= 3) return 'proper_name';
    return 'phrase';
  }

  String _contextBefore(String content, int position) {
    final start =
        (position - occurrenceContextHalfWidth).clamp(0, content.length);
    return content.substring(start, position).replaceAll('\n', ' ').trim();
  }

  String _contextAfter(String content, int endChar) {
    final stop =
        (endChar + occurrenceContextHalfWidth).clamp(0, content.length);
    return content.substring(endChar, stop).replaceAll('\n', ' ').trim();
  }

  static String _collapseWhitespace(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static bool _isNonLatinScript(String lang) {
    return const {'zh', 'ja', 'ko'}.contains(lang);
  }
}

class _NgramCounter {
  _NgramCounter({
    required this.sourceText,
    required this.firstChapterId,
    required this.orderIndex,
    required this.firstPosition,
  });
  final String sourceText;
  final int firstChapterId;
  final int orderIndex;
  final int firstPosition;
  int frequency = 0;
  final Set<int> chapterIds = <int>{};
  final Map<int, int> chapterFrequencies = <int, int>{};
}

const Set<String> _orgSuffixes = {
  'sect', 'clan', 'academy', 'guild', 'empire', 'kingdom', 'tower',
  'school', 'order', 'temple', 'palace', 'hall', 'pavilion',
};

const Set<String> _techSuffixes = {
  'art', 'technique', 'method', 'scripture', 'formation', 'seal', 'mantra',
  'sword', 'fist', 'palm', 'sutra', 'manual',
};

const Set<String> _titlePrefixes = {
  'elder', 'master', 'lord', 'lady', 'sir', 'dame', 'duke', 'duchess',
  'count', 'baron', 'king', 'queen', 'emperor', 'empress', 'prince',
  'princess', 'chief', 'captain', 'general', 'commander', 'dean',
  'principal',
};
