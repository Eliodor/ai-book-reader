/// A candidate translation variant for a given source term during Stage C
/// mining. Multiple variants accumulate across chapters; the most frequent one
/// becomes the winning glossary entry at aggregation time.
///
/// `termTargetNormalized` is the dedup key (Unicode NFC + lower-case + collapsed
/// whitespace). `termTargetDisplay` preserves the casing of the first
/// occurrence for UI surfacing.
class GlossaryTermVariant {
  GlossaryTermVariant({
    this.id,
    required this.bookId,
    required this.termSource,
    required this.termTargetNormalized,
    required this.termTargetDisplay,
    this.count = 1,
    this.firstChapterId,
    DateTime? createTime,
    DateTime? updateTime,
  })  : createTime = createTime ?? DateTime.now(),
        updateTime = updateTime ?? DateTime.now();

  int? id;
  int bookId;
  String termSource;
  String termTargetNormalized;
  String termTargetDisplay;
  int count;
  int? firstChapterId;
  DateTime createTime;
  DateTime updateTime;

  GlossaryTermVariant copyWith({
    int? id,
    int? bookId,
    String? termSource,
    String? termTargetNormalized,
    String? termTargetDisplay,
    int? count,
    int? firstChapterId,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return GlossaryTermVariant(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      termSource: termSource ?? this.termSource,
      termTargetNormalized: termTargetNormalized ?? this.termTargetNormalized,
      termTargetDisplay: termTargetDisplay ?? this.termTargetDisplay,
      count: count ?? this.count,
      firstChapterId: firstChapterId ?? this.firstChapterId,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'term_source': termSource,
      'term_target_normalized': termTargetNormalized,
      'term_target_display': termTargetDisplay,
      'count': count,
      'first_chapter_id': firstChapterId,
      'create_time': createTime.toIso8601String(),
      'update_time': updateTime.toIso8601String(),
    };
  }

  factory GlossaryTermVariant.fromDb(Map<String, dynamic> map) {
    final now = DateTime.now();
    final createTimeString = map['create_time'] as String?;
    final updateTimeString = map['update_time'] as String?;

    return GlossaryTermVariant(
      id: map['id'] as int?,
      bookId: map['book_id'] as int,
      termSource: map['term_source'] as String? ?? '',
      termTargetNormalized: map['term_target_normalized'] as String? ?? '',
      termTargetDisplay: map['term_target_display'] as String? ?? '',
      count: (map['count'] as int?) ?? 0,
      firstChapterId: map['first_chapter_id'] as int?,
      createTime: createTimeString != null
          ? DateTime.tryParse(createTimeString) ?? now
          : now,
      updateTime: updateTimeString != null
          ? DateTime.tryParse(updateTimeString) ?? now
          : now,
    );
  }
}
