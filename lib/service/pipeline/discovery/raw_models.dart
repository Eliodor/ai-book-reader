// Plain-data structs used inside the Stage A pipeline. They live in their
// own file so each scoring stage doesn't need to depend on the orchestrator.

class RawCandidate {
  RawCandidate({
    required this.sourceText,
    required this.normalizedSource,
    required this.candidateType,
    required this.wordCount,
  });

  String sourceText;
  String normalizedSource;

  /// Stable DB string ("proper_name", "title", "organization", "technique",
  /// "phrase", "unknown") — matches [CandidateType.dbValue].
  String candidateType;
  int wordCount;

  /// Total token occurrences in the book.
  int frequencyTotal = 0;

  /// Chapters that contain at least one occurrence.
  final Set<int> chapterIds = <int>{};

  int? firstChapterId;

  /// Number of times the candidate text was written in ALL CAPS. Drives the
  /// T_Case YAKE feature.
  int allCapsOccurrences = 0;

  /// Unique 0-based sentence indices (book-wide, but using
  /// `chapterOrderIndex * 1_000_000 + sentenceIndex`) used for T_DifSentence.
  final Set<int> uniqueSentences = <int>{};

  /// All occurrences we still want to surface to later stages (for context
  /// snippets, dispersion, substring containment). Trimmed by the final stage.
  final List<RawOccurrence> occurrences = <RawOccurrence>[];

  /// Indices of longer candidates that contain this one as a sub-phrase
  /// — populated by Stage 2 / 5.
  final Set<int> superCandidateIndices = <int>{};

  /// Frequency of this candidate counted only as a sub-phrase of a longer
  /// candidate. Stage 5 uses ratio (nested / total) to decide soft penalty.
  int nestedFrequency = 0;

  /// Running score across the 5 scoring stages.
  double score = 0;
}

class RawOccurrence {
  RawOccurrence({
    required this.chapterId,
    required this.orderIndex,
    required this.position,
    required this.contextBefore,
    required this.contextAfter,
    required this.sentenceIndex,
    this.isAllCapsForm = false,
  });

  final int chapterId;
  final int orderIndex;
  final int position;
  final String contextBefore;
  final String contextAfter;
  final int sentenceIndex;
  final bool isAllCapsForm;
}

/// Snapshot of a chapter we ship to the Isolate. Avoids passing live DB
/// objects which can't cross isolate boundaries.
class ChapterSnapshot {
  ChapterSnapshot({
    required this.id,
    required this.orderIndex,
    required this.content,
  });

  final int id;
  final int orderIndex;
  final String content;
}
