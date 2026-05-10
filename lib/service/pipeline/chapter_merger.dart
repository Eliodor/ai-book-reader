import 'dart:convert';

import 'package:ai_book_reader/utils/chapter_number_extractor.dart';

/// A chapter freshly fetched from the book TOC, before merge.
class RawChapter {
  const RawChapter({required this.title, required this.content});

  final String title;
  final String content;
}

/// One entry in the `merged_from` JSON array — used to remember that the
/// final row absorbed several sub-chapter pieces (`1.1`, `1.2`, ...).
class MergedFromEntry {
  const MergedFromEntry({required this.title, required this.subIndex});

  final String title;
  final int subIndex;

  Map<String, dynamic> toJson() => {
        'title': title,
        'sub_index': subIndex,
      };
}

/// A chapter row ready to be persisted. `mergedFrom` is empty if the chapter
/// was a standalone heading (no sub-chapter aggregation happened).
class MergedChapter {
  const MergedChapter({
    required this.title,
    required this.content,
    required this.chapterNumber,
    required this.mergedFrom,
  });

  final String title;
  final String content;
  final int? chapterNumber;
  final List<MergedFromEntry> mergedFrom;

  /// Serialises [mergedFrom] into the `meta` column. Empty `merged_from` is
  /// elided so the JSON stays compact (`{}`) for non-merged chapters.
  String get metaJson {
    if (mergedFrom.isEmpty) return '{}';
    return jsonEncode({
      'merged_from': mergedFrom.map((e) => e.toJson()).toList(),
    });
  }
}

/// Merges sub-chapters and de-duplicates by `chapter_number`.
///
/// Strategy:
/// 1. Run [extractChapterNumber] over every title (with content fallback).
/// 2. Group numbered chapters by canonical `number`.
/// 3. Emit one [MergedChapter] per group at the **first** position the number
///    appears in TOC order. Multi-element groups concatenate their content
///    via `\n\n` and record `mergedFrom`.
/// 4. Unnumbered chapters (Chinese numerals, untitled, plain prose) stay in
///    place with `chapterNumber == null`. They are not aligned across the
///    original ↔ reference pair.
class ChapterMerger {
  const ChapterMerger._();

  static List<MergedChapter> merge(List<RawChapter> chapters) {
    if (chapters.isEmpty) return const [];

    final extracted = <_ExtractedRaw>[];
    for (final raw in chapters) {
      final match = extractChapterNumber(
        raw.title,
        contentPrefix: raw.content,
      );
      extracted.add(_ExtractedRaw(
        title: raw.title,
        content: raw.content,
        chapterNumber: match?.number,
        subIndex: match?.subIndex,
      ));
    }

    final groups = <int, List<_ExtractedRaw>>{};
    for (final e in extracted) {
      final n = e.chapterNumber;
      if (n == null) continue;
      groups.putIfAbsent(n, () => []).add(e);
    }

    final emitted = <int>{};
    final result = <MergedChapter>[];

    for (final e in extracted) {
      final n = e.chapterNumber;
      if (n == null) {
        result.add(MergedChapter(
          title: e.title,
          content: e.content,
          chapterNumber: null,
          mergedFrom: const [],
        ));
        continue;
      }

      if (emitted.contains(n)) continue;
      emitted.add(n);

      final group = groups[n]!;
      if (group.length == 1) {
        result.add(MergedChapter(
          title: e.title,
          content: e.content,
          chapterNumber: n,
          mergedFrom: const [],
        ));
        continue;
      }

      final mergedContent = group.map((g) => g.content).join('\n\n');
      final mergedFrom = <MergedFromEntry>[];
      for (var i = 0; i < group.length; i++) {
        final g = group[i];
        mergedFrom.add(MergedFromEntry(
          title: g.title,
          subIndex: g.subIndex ?? (i + 1),
        ));
      }
      result.add(MergedChapter(
        title: group.first.title,
        content: mergedContent,
        chapterNumber: n,
        mergedFrom: mergedFrom,
      ));
    }

    return result;
  }
}

class _ExtractedRaw {
  _ExtractedRaw({
    required this.title,
    required this.content,
    required this.chapterNumber,
    required this.subIndex,
  });

  final String title;
  final String content;
  final int? chapterNumber;
  final int? subIndex;
}
