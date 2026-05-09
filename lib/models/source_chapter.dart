import 'package:ai_book_reader/models/chapter_status.dart';

/// One chapter in the original (untranslated) language.
///
/// Ported from `D:\Projects\NovelTranslator\core\database\models.py::SourceChapter`.
/// On mobile every row carries `bookId` because one SQLite database stores many
/// books, unlike the Python project where one DB == one project.
class SourceChapter {
  SourceChapter({
    this.id,
    required this.bookId,
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
  String title;
  int orderIndex;
  String content;
  ChapterStatus status;
  String meta;
  DateTime createTime;
  DateTime updateTime;

  SourceChapter copyWith({
    int? id,
    int? bookId,
    String? title,
    int? orderIndex,
    String? content,
    ChapterStatus? status,
    String? meta,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return SourceChapter(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
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
      'title': title,
      'order_index': orderIndex,
      'content': content,
      'status': status.dbValue,
      'meta': meta,
      'create_time': createTime.toIso8601String(),
      'update_time': updateTime.toIso8601String(),
    };
  }

  factory SourceChapter.fromDb(Map<String, dynamic> map) {
    final createTimeString = map['create_time'] as String?;
    final updateTimeString = map['update_time'] as String?;
    final now = DateTime.now();

    return SourceChapter(
      id: map['id'] as int?,
      bookId: map['book_id'] as int,
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
