/// Lifecycle of a reference-translation parsing job.
enum ReferenceParsingStatus {
  pending('pending'),
  parsing('parsing'),
  parsed('parsed'),
  failed('failed');

  const ReferenceParsingStatus(this.dbValue);

  final String dbValue;

  static ReferenceParsingStatus fromDb(String? raw) {
    if (raw == null) return ReferenceParsingStatus.pending;
    for (final value in ReferenceParsingStatus.values) {
      if (value.dbValue == raw) return value;
    }
    return ReferenceParsingStatus.pending;
  }
}

/// One file the user has attached as a human translation of a book.
///
/// A book can have many parts — typically when the translation is published
/// in volumes. Each part is parsed into [tb_reference_chapters] independently
/// and aligned with the original by `chapter_number`.
class ReferenceTranslation {
  ReferenceTranslation({
    this.id,
    required this.bookId,
    required this.filePath,
    required this.fileName,
    this.md5,
    required this.partOrder,
    this.parsingStatus = ReferenceParsingStatus.pending,
    this.parsingError,
    this.meta = '{}',
    DateTime? createTime,
    DateTime? updateTime,
  })  : createTime = createTime ?? DateTime.now(),
        updateTime = updateTime ?? DateTime.now();

  int? id;
  int bookId;
  String filePath;
  String fileName;
  String? md5;
  int partOrder;
  ReferenceParsingStatus parsingStatus;
  String? parsingError;
  String meta;
  DateTime createTime;
  DateTime updateTime;

  ReferenceTranslation copyWith({
    int? id,
    int? bookId,
    String? filePath,
    String? fileName,
    String? md5,
    int? partOrder,
    ReferenceParsingStatus? parsingStatus,
    String? parsingError,
    String? meta,
    DateTime? createTime,
    DateTime? updateTime,
  }) {
    return ReferenceTranslation(
      id: id ?? this.id,
      bookId: bookId ?? this.bookId,
      filePath: filePath ?? this.filePath,
      fileName: fileName ?? this.fileName,
      md5: md5 ?? this.md5,
      partOrder: partOrder ?? this.partOrder,
      parsingStatus: parsingStatus ?? this.parsingStatus,
      parsingError: parsingError ?? this.parsingError,
      meta: meta ?? this.meta,
      createTime: createTime ?? this.createTime,
      updateTime: updateTime ?? this.updateTime,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'file_path': filePath,
      'file_name': fileName,
      'md5': md5,
      'part_order': partOrder,
      'parsing_status': parsingStatus.dbValue,
      'parsing_error': parsingError,
      'meta': meta,
      'create_time': createTime.toIso8601String(),
      'update_time': updateTime.toIso8601String(),
    };
  }

  factory ReferenceTranslation.fromDb(Map<String, dynamic> map) {
    final createTimeString = map['create_time'] as String?;
    final updateTimeString = map['update_time'] as String?;
    final now = DateTime.now();

    return ReferenceTranslation(
      id: map['id'] as int?,
      bookId: map['book_id'] as int,
      filePath: map['file_path'] as String? ?? '',
      fileName: map['file_name'] as String? ?? '',
      md5: map['md5'] as String?,
      partOrder: map['part_order'] as int? ?? 0,
      parsingStatus:
          ReferenceParsingStatus.fromDb(map['parsing_status'] as String?),
      parsingError: map['parsing_error'] as String?,
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
