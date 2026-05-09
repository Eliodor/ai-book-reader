import 'package:ai_book_reader/models/chapter_status.dart';

/// One translated chapter, paired with a `SourceChapter` by `sourceChapterId`.
///
/// Ported from `D:\Projects\NovelTranslator\core\database\models.py::TargetChapter`.
/// The Python schema matched source/target by `order_index` alone; here we
/// keep an explicit FK on `source_chapter_id` so reordering or insertions on
/// the source side do not silently break alignment.
class TargetChapter {
  TargetChapter({
    this.id,
    required this.bookId,
    required this.sourceChapterId,
    required this.title,
    required this.orderIndex,
    this.content = '',
    this.status = ChapterStatus.newly,
    this.meta = '{}',
    DateTime? createTime,
    DateTime? updateTime,
  })  : createTime = createTime ?? DateTime.now(),
        updateTime = updateTime ?? DateTime.now();

  int? id;
  int bookId;
  int sourceChapterId;
  String title;
  int orderIndex;
  String content;
  ChapterStatus status;
  String meta;
  DateTime createTime;
  DateTime updateTime;

  TargetChapter copyWith({
    int? id,
    int? bookId,
    int? sourceChapterId,
    String? title,
    int? orderIndex,
    String? content,
    ChapterStatus? status,
    String? meta,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return TargetChapter(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      sourceChapterId: sourceChapterId ?? this.sourceChapterId,
      title: title ?? this.title,
      orderIndex: orderIndex ?? this.orderIndex,
      content: content ?? this.content,
      status: status ?? this.status,
      meta: meta ?? this.meta,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'source_chapter_id': sourceChapterId,
      'title': title,
      'order_index': orderIndex,
      'content': content,
      'status': status.dbValue,
      'meta': meta,
      'create_time': createTime.toIso8601String(),
      'update_time': updateTime.toIso8601String(),
    };
  }

  factory TargetChapter.fromDb(Map<String, dynamic> map) {
    final createTimeString = map['create_time'] as String?;
    final updateTimeString = map['update_time'] as String?;
    final now = DateTime.now();

    return TargetChapter(
      id: map['id'] as int?,
      bookId: map['book_id'] as int,
      sourceChapterId: map['source_chapter_id'] as int,
      title: map['title'] as String? ?? '',
      orderIndex: map['order_index'] as int? ?? 0,
      content: map['content'] as String? ?? '',
      status: ChapterStatus.fromDb(map['status'] as String?),
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
