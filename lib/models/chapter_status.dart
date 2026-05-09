/// Pipeline state for a single chapter (source or target).
///
/// Ported from `D:\Projects\NovelTranslator\core\database\models.py::ChapterStatus`.
/// The legacy `cleaned` / `mined` values belonged to upstream-deleted steps and
/// are intentionally not ported.
enum ChapterStatus {
  /// Inserted but not yet parsed.
  newly('new'),

  /// Imported and content extracted from the source book.
  parsed('parsed'),

  /// LLM translation written to the target chapter row.
  translated('translated'),

  /// N-gram / candidate analysis run over the chapter.
  analyzed('analyzed');

  const ChapterStatus(this.dbValue);

  /// Stable string written to SQLite. Matches the Python enum values so a
  /// cross-platform export/import would line up.
  final String dbValue;

  static ChapterStatus fromDb(String? raw) {
    if (raw == null) return ChapterStatus.newly;
    for (final value in ChapterStatus.values) {
      if (value.dbValue == raw) return value;
    }
    return ChapterStatus.newly;
  }
}
