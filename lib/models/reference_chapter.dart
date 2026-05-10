/// One chapter extracted from a [ReferenceTranslation] file.
///
/// `bookId` is denormalised here (also lives on the parent
/// `tb_reference_translations` row) so alignment queries can JOIN directly
/// on `(book_id, chapter_number)` without hopping through the parent table.
class ReferenceChapter {
  ReferenceChapter({
    this.id,
    required this.referenceTranslationId,
    required this.bookId,
    required this.title,
    required this.orderIndex,
    this.chapterNumber,
    this.content = '',
    this.meta = '{}',
    DateTime? createTime,
    DateTime? updateTime,
  })  : createTime = createTime ?? DateTime.now(),
        updateTime = updateTime ?? DateTime.now();

  int? id;
  int referenceTranslationId;
  int bookId;
  String title;
  int orderIndex;
  int? chapterNumber;
  String content;
  String meta;
  DateTime createTime;
  DateTime updateTime;

  ReferenceChapter copyWith({
    int? id,
    int? referenceTranslationId,
    int? bookId,
    String? title,
    int? orderIndex,
    int? chapterNumber,
    String? content,
    String? meta,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return ReferenceChapter(
      id: id ?? this.id,
      referenceTranslationId:
          referenceTranslationId ?? this.referenceTranslationId,
      bookId: bookId ?? this.bookId,
      title: title ?? this.title,
      orderIndex: orderIndex ?? this.orderIndex,
      chapterNumber: chapterNumber ?? this.chapterNumber,
      content: content ?? this.content,
      meta: meta ?? this.meta,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'reference_translation_id': referenceTranslationId,
      'book_id': bookId,
      'title': title,
      'order_index': orderIndex,
      'chapter_number': chapterNumber,
      'content': content,
      'meta': meta,
      'create_time': createTime.toIso8601String(),
      'update_time': updateTime.toIso8601String(),
    };
  }

  factory ReferenceChapter.fromDb(Map<String, dynamic> map) {
    final createTimeString = map['create_time'] as String?;
    final updateTimeString = map['update_time'] as String?;
    final now = DateTime.now();

    return ReferenceChapter(
      id: map['id'] as int?,
      referenceTranslationId: map['reference_translation_id'] as int,
      bookId: map['book_id'] as int,
      title: map['title'] as String? ?? '',
      orderIndex: map['order_index'] as int? ?? 0,
      chapterNumber: map['chapter_number'] as int?,
      content: map['content'] as String? ?? '',
      meta: map['meta'] as String? ?? '{}',
      createTime: createTimeString != null
          ? DateTime.tryParse(createTimeString) ?? now
          : now,
      updateTime: updateTimeString != null
          ? DateTime.tryParse(updateTimeString) ?? now
          : now,
    );
  }
}
