/// A single occurrence of a term candidate inside one source chapter.
///
/// `position` is the character offset inside the chapter content; contexts are
/// short snippets (typically up to 60 chars on each side) shown to the LLM
/// filter and useful for UI inspection later.
class TermCandidateOccurrence {
  TermCandidateOccurrence({
    this.id,
    required this.candidateId,
    required this.chapterId,
    required this.orderIndex,
    this.position = 0,
    this.contextBefore = '',
    this.contextAfter = '',
  });

  int? id;
  int candidateId;
  int chapterId;
  int orderIndex;
  int position;
  String contextBefore;
  String contextAfter;

  TermCandidateOccurrence copyWith({
    int? id,
    int? candidateId,
    int? chapterId,
    int? orderIndex,
    int? position,
    String? contextBefore,
    String? contextAfter,
  }) {
    return TermCandidateOccurrence(
      id: id ?? this.id,
      candidateId: candidateId ?? this.candidateId,
      chapterId: chapterId ?? this.chapterId,
      orderIndex: orderIndex ?? this.orderIndex,
      position: position ?? this.position,
      contextBefore: contextBefore ?? this.contextBefore,
      contextAfter: contextAfter ?? this.contextAfter,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'candidate_id': candidateId,
      'chapter_id': chapterId,
      'order_index': orderIndex,
      'position': position,
      'context_before': contextBefore,
      'context_after': contextAfter,
    };
  }

  factory TermCandidateOccurrence.fromDb(Map<String, dynamic> map) {
    return TermCandidateOccurrence(
      id: map['id'] as int?,
      candidateId: map['candidate_id'] as int,
      chapterId: map['chapter_id'] as int,
      orderIndex: (map['order_index'] as int?) ?? 0,
      position: (map['position'] as int?) ?? 0,
      contextBefore: map['context_before'] as String? ?? '',
      contextAfter: map['context_after'] as String? ?? '',
    );
  }
}
