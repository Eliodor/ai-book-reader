/// Glossary term mapping a source-language term to its target-language
/// translation, scoped to a single book.
///
/// Ported from `D:\Projects\NovelTranslator\core\database\models.py::GlossaryTerm`.
/// On mobile we use a synthetic auto-increment id (Python used `term_source` as
/// the primary key) so the same word can have different translations across
/// books; uniqueness is enforced via `(book_id, term_source)`.
class GlossaryTerm {
  GlossaryTerm({
    this.id,
    required this.bookId,
    required this.termSource,
    required this.termTarget,
    this.sourceChapterId,
    DateTime? createTime,
    DateTime? updateTime,
  })  : createTime = createTime ?? DateTime.now(),
        updateTime = updateTime ?? DateTime.now();

  int? id;
  int bookId;
  String termSource;
  String termTarget;
  int? sourceChapterId;
  DateTime createTime;
  DateTime updateTime;

  GlossaryTerm copyWith({
    int? id,
    int? bookId,
    String? termSource,
    String? termTarget,
    int? sourceChapterId,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return GlossaryTerm(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      termSource: termSource ?? this.termSource,
      termTarget: termTarget ?? this.termTarget,
      sourceChapterId: sourceChapterId ?? this.sourceChapterId,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'term_source': termSource,
      'term_target': termTarget,
      'source_chapter_id': sourceChapterId,
      'create_time': createTime.toIso8601String(),
      'update_time': updateTime.toIso8601String(),
    };
  }

  factory GlossaryTerm.fromDb(Map<String, dynamic> map) {
    final createTimeString = map['create_time'] as String?;
    final updateTimeString = map['update_time'] as String?;
    final now = DateTime.now();

    return GlossaryTerm(
      id: map['id'] as int?,
      bookId: map['book_id'] as int,
      termSource: map['term_source'] as String? ?? '',
      termTarget: map['term_target'] as String? ?? '',
      sourceChapterId: map['source_chapter_id'] as int?,
      createTime:
          createTimeString != null ? DateTime.tryParse(createTimeString) ?? now : now,
      updateTime:
          updateTimeString != null ? DateTime.tryParse(updateTimeString) ?? now : now,
    );
  }
}
