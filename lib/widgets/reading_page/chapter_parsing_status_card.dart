import 'package:ai_book_reader/dao/source_chapter_dao.dart';
import 'package:ai_book_reader/providers/chapter_parsing.dart';
import 'package:ai_book_reader/widgets/common/container/filled_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Full-width status card for the chapter-parsing pass, intended for the
/// Book Details screen. Shows live progress when the parser is running, a
/// success summary after completion, or the cached chapter count from the DB
/// when the parser hasn't been launched yet in this session.
class ChapterParsingStatusCard extends ConsumerWidget {
  const ChapterParsingStatusCard({super.key, required this.bookId});

  final int bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(chapterParsingProvider(bookId));

    if (state is ChapterParsingRunning) {
      return _Card(
        icon: const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        title: 'Парсинг глав',
        subtitle: '${state.done} / ${state.total}',
        progress: state.total == 0 ? null : state.done / state.total,
      );
    }

    if (state is ChapterParsingDone) {
      return _Card(
        icon: Icon(Icons.check_circle,
            color: Theme.of(context).colorScheme.primary),
        title: 'Главы извлечены',
        subtitle: 'Готово к переводу: ${state.total}',
      );
    }

    if (state is ChapterParsingFailed) {
      return _Card(
        icon: Icon(Icons.error_outline,
            color: Theme.of(context).colorScheme.error),
        title: 'Парсинг прерван',
        subtitle:
            'Сохранено ${state.done} из ${state.total}. Откройте книгу, чтобы продолжить.',
      );
    }

    // Idle — fall back to the persistent count in tb_source_chapters.
    return FutureBuilder<int>(
      future: sourceChapterDao.countByBookId(bookId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const _Card(
            icon: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            title: 'Главы',
            subtitle: 'Проверка состояния…',
          );
        }
        final count = snapshot.data ?? 0;
        if (count == 0) {
          return _Card(
            icon: Icon(Icons.menu_book_outlined,
                color: Theme.of(context).colorScheme.outline),
            title: 'Главы',
            subtitle: 'Не извлечены. Откройте книгу — парсинг запустится в фоне.',
          );
        }
        return _Card(
          icon: Icon(Icons.check_circle_outline,
              color: Theme.of(context).colorScheme.primary),
          title: 'Главы извлечены',
          subtitle: 'Готово к переводу: $count',
        );
      },
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.progress,
  });

  final Widget icon;
  final String title;
  final String subtitle;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilledContainer(
      width: MediaQuery.of(context).size.width,
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          SizedBox(width: 22, height: 22, child: icon),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
                if (progress != null) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
