import 'package:ai_book_reader/models/chapter_split_presets.dart';

/// Result of extracting a numeric chapter identifier from a chapter title.
///
/// `number` is the canonical (parent) chapter number — what becomes the
/// `chapter_number` column for alignment between original and reference
/// translations. `subIndex` is non-null only for split chapters such as
/// `1.1 / 1.2 / 1.3`, where it carries the position inside the parent group.
class ChapterNumberMatch {
  const ChapterNumberMatch({required this.number, this.subIndex});

  final int number;
  final int? subIndex;
}

final RegExp _arabicChapterNumberRegExp = RegExp(r'(\d+)(?:[._\-](\d+))?');

/// Extracts a chapter number (and optional sub-index) from a chapter title,
/// falling back to the first 200 characters of [contentPrefix] if the title is
/// empty or unrecognised.
///
/// Uses the project-wide universal `Default (mixed languages)` rule from
/// [getDefaultChapterSplitRule] to confirm the text looks like a chapter
/// heading before pulling a number out of it. Chinese numerals (`第一章`) are
/// detected by the rule but not converted to digits — those titles return
/// `null` and stay unaligned in this iteration.
ChapterNumberMatch? extractChapterNumber(
  String title, {
  String contentPrefix = '',
}) {
  final rule = getDefaultChapterSplitRule().buildRegExp();

  final fromTitle = _tryExtract(title, rule);
  if (fromTitle != null) return fromTitle;

  if (contentPrefix.isEmpty) return null;
  final head = contentPrefix.length > 200
      ? contentPrefix.substring(0, 200)
      : contentPrefix;
  return _tryExtract(head, rule);
}

ChapterNumberMatch? _tryExtract(String text, RegExp chapterRule) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  if (!chapterRule.hasMatch(trimmed)) return null;

  final match = _arabicChapterNumberRegExp.firstMatch(trimmed);
  if (match == null) return null;

  final number = int.tryParse(match.group(1) ?? '');
  if (number == null) return null;

  final subRaw = match.group(2);
  final subIndex = subRaw == null ? null : int.tryParse(subRaw);
  return ChapterNumberMatch(number: number, subIndex: subIndex);
}
