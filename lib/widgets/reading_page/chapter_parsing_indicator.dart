import 'package:ai_book_reader/providers/chapter_parsing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Compact progress chip rendered while the first-open chapter parser fills
/// `tb_source_chapters` for the given book. Renders nothing when idle. Stays
/// visible after `Done` so the user can see the final count.
class ChapterParsingIndicator extends ConsumerWidget {
  const ChapterParsingIndicator({super.key, required this.bookId});

  final int bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chapterParsingProvider(bookId));
    final theme = Theme.of(context);

    String? label;
    double? fraction;
    bool isError = false;
    bool finished = false;

    if (state is ChapterParsingRunning) {
      label = 'Парсинг глав: ${state.done} / ${state.total}';
      fraction = state.total == 0 ? null : state.done / state.total;
    } else if (state is ChapterParsingDone) {
      label = 'Главы готовы: ${state.total}';
      finished = true;
    } else if (state is ChapterParsingFailed) {
      label = 'Парсинг прерван на ${state.done} / ${state.total}';
      isError = true;
    }

    if (label == null) {
      return const SizedBox.shrink();
    }

    final color = isError
        ? theme.colorScheme.error
        : finished
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurfaceVariant;

    final Widget leading;
    if (finished) {
      leading = Icon(Icons.check_circle, size: 16, color: color);
    } else if (isError) {
      leading = Icon(Icons.error_outline, size: 16, color: color);
    } else {
      leading = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: fraction,
          color: color,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
