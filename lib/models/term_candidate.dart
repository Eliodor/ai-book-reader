import 'package:ai_book_reader/models/candidate_status.dart';
import 'package:ai_book_reader/models/candidate_type.dart';

/// A term candidate produced by Stage A discovery for a single book.
///
/// `normalizedSource` is the case-folded + NFC-normalised key used for
/// uniqueness within a book. `sourceText` keeps the original casing for
/// display.
class TermCandidate {
  TermCandidate({
    this.id,
    required this.bookId,
    required this.sourceText,
    required this.normalizedSource,
    this.candidateType = CandidateType.phrase,
    this.score = 0,
    this.frequencyTotal = 0,
    this.chapterCount = 0,
    this.firstChapterId,
    this.status = CandidateStatus.candidate,
    this.llmVerdict,
    this.llmReason,
    this.filteredAt,
    this.promotedAt,
    DateTime? createTime,
    DateTime? updateTime,
  })  : createTime = createTime ?? DateTime.now(),
        updateTime = updateTime ?? DateTime.now();

  int? id;
  int bookId;
  String sourceText;
  String normalizedSource;
  CandidateType candidateType;
  double score;
  int frequencyTotal;
  int chapterCount;
  int? firstChapterId;
  CandidateStatus status;
  String? llmVerdict;
  String? llmReason;
  DateTime? filteredAt;
  DateTime? promotedAt;
  DateTime createTime;
  DateTime updateTime;

  TermCandidate copyWith({
    int? id,
    int? bookId,
    String? sourceText,
    String? normalizedSource,
    CandidateType? candidateType,
    double? score,
    int? frequencyTotal,
    int? chapterCount,
    int? firstChapterId,
    CandidateStatus? status,
    String? llmVerdict,
    String? llmReason,
    DateTime? filteredAt,
    DateTime? promotedAt,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return TermCandidate(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      sourceText: sourceText ?? this.sourceText,
      normalizedSource: normalizedSource ?? this.normalizedSource,
      candidateType: candidateType ?? this.candidateType,
      score: score ?? this.score,
      frequencyTotal: frequencyTotal ?? this.frequencyTotal,
      chapterCount: chapterCount ?? this.chapterCount,
      firstChapterId: firstChapterId ?? this.firstChapterId,
      status: status ?? this.status,
      llmVerdict: llmVerdict ?? this.llmVerdict,
      llmReason: llmReason ?? this.llmReason,
      filteredAt: filteredAt ?? this.filteredAt,
      promotedAt: promotedAt ?? this.promotedAt,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'source_text': sourceText,
      'normalized_source': normalizedSource,
      'candidate_type': candidateType.dbValue,
      'score': score,
      'frequency_total': frequencyTotal,
      'chapter_count': chapterCount,
      'first_chapter_id': firstChapterId,
      'status': status.dbValue,
      'llm_verdict': llmVerdict,
      'llm_reason': llmReason,
      'filtered_at': filteredAt?.toIso8601String(),
      'promoted_at': promotedAt?.toIso8601String(),
      'create_time': createTime.toIso8601String(),
      'update_time': updateTime.toIso8601String(),
    };
  }

  factory TermCandidate.fromDb(Map<String, dynamic> map) {
    final now = DateTime.now();
    final createTimeString = map['create_time'] as String?;
    final updateTimeString = map['update_time'] as String?;
    final filteredString = map['filtered_at'] as String?;
    final promotedString = map['promoted_at'] as String?;

    return TermCandidate(
      id: map['id'] as int?,
      bookId: map['book_id'] as int,
      sourceText: map['source_text'] as String? ?? '',
      normalizedSource: map['normalized_source'] as String? ?? '',
      candidateType: CandidateType.fromDb(map['candidate_type'] as String?),
      score: (map['score'] as num?)?.toDouble() ?? 0.0,
      frequencyTotal: (map['frequency_total'] as int?) ?? 0,
      chapterCount: (map['chapter_count'] as int?) ?? 0,
      firstChapterId: map['first_chapter_id'] as int?,
      status: CandidateStatus.fromDb(map['status'] as String?),
      llmVerdict: map['llm_verdict'] as String?,
      llmReason: map['llm_reason'] as String?,
      filteredAt:
          filteredString != null ? DateTime.tryParse(filteredString) : null,
      promotedAt:
          promotedString != null ? DateTime.tryParse(promotedString) : null,
      createTime: createTimeString != null
          ? DateTime.tryParse(createTimeString) ?? now
          : now,
      updateTime: updateTimeString != null
          ? DateTime.tryParse(updateTimeString) ?? now
          : now,
    );
  }
}
