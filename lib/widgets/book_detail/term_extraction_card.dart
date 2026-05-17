import 'package:ai_book_reader/config/shared_preference_provider.dart';
import 'package:ai_book_reader/providers/term_extraction.dart';
import 'package:ai_book_reader/widgets/common/container/filled_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Book Detail card driving the term-extraction pipeline (Discovery →
/// LLM filter → Pair mining). Mirrors the layout of `ChapterParsingStatusCard`
/// and `ReferenceTranslationsCard`.
class TermExtractionCard extends ConsumerWidget {
  const TermExtractionCard({super.key, required this.bookId});

  final int bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(termExtractionProvider(bookId));
    final theme = Theme.of(context);

    final discoveryProgress = _discoveryProgress(state);
    final filterProgress = _filterProgress(state);
    final miningProgress = _miningProgress(state);

    final isRunning = state is TermExtractionDiscoveryRunning ||
        state is TermExtractionFilterRunning ||
        state is TermExtractionMiningRunning;

    final summary = _summary(state);

    return FilledContainer(
      width: MediaQuery.of(context).size.width,
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.workspaces_outline,
                  size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Витяг глосарію',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (state is TermExtractionFailed)
                Icon(Icons.error_outline,
                    size: 18, color: theme.colorScheme.error),
            ],
          ),
          const SizedBox(height: 10),
          _StageRow(
            label: 'Пошук термінів',
            progress: discoveryProgress,
            sublabel: _discoveryStageLabel(state),
          ),
          _StageRow(
            label: 'AI-фільтр сміття',
            progress: filterProgress.value,
            sublabel: filterProgress.label,
          ),
          _StageRow(
            label: 'Парний майнинг',
            progress: miningProgress.value,
            sublabel: miningProgress.label,
          ),
          if (summary != null) ...[
            const SizedBox(height: 8),
            Text(
              summary,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              FilledButton.icon(
                onPressed: isRunning
                    ? null
                    : () => _start(ref),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Запустити'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: isRunning
                    ? () => ref.read(termExtractionProvider(bookId).notifier).cancel()
                    : null,
                icon: const Icon(Icons.stop_rounded, size: 18),
                label: const Text('Скасувати'),
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Скинути та почати спочатку',
                onPressed: isRunning
                    ? null
                    : () => ref
                        .read(termExtractionProvider(bookId).notifier)
                        .reset(),
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _start(WidgetRef ref) async {
    final toLocale = Prefs().locale?.languageCode ?? defaultTargetLocale;
    // Discovery itself detects the source language; we pass 'auto' through
    // and let the service override after detection.
    await ref.read(termExtractionProvider(bookId).notifier).start(
          fromLocale: 'auto',
          toLocale: toLocale,
        );
  }

  double? _discoveryProgress(TermExtractionState state) {
    if (state is TermExtractionDiscoveryRunning) return null; // indeterminate
    if (state is TermExtractionFilterRunning ||
        state is TermExtractionMiningRunning ||
        state is TermExtractionDone) {
      return 1.0;
    }
    return 0.0;
  }

  String? _discoveryStageLabel(TermExtractionState state) {
    if (state is TermExtractionDiscoveryRunning) {
      switch (state.stage) {
        case 'load-chapters':
          return 'Читання розділів…';
        case 'detect-language':
          return 'Визначення мови…';
        case 'discover':
          return 'Аналіз корпусу…';
        case 'persist':
          return 'Збереження кандидатів…';
        default:
          return state.stage;
      }
    }
    if (state is TermExtractionDone) {
      return 'Знайдено: ${state.candidatesDiscovered}';
    }
    return null;
  }

  _ProgressInfo _filterProgress(TermExtractionState state) {
    if (state is TermExtractionFilterRunning) {
      final p = state.total == 0 ? null : state.done / state.total;
      return _ProgressInfo(p, '${state.done} / ${state.total}');
    }
    if (state is TermExtractionMiningRunning ||
        state is TermExtractionDone) {
      return _ProgressInfo(
        1.0,
        state is TermExtractionDone
            ? 'Прийнято: ${state.candidatesAccepted}'
            : null,
      );
    }
    return _ProgressInfo(0.0, null);
  }

  _ProgressInfo _miningProgress(TermExtractionState state) {
    if (state is TermExtractionMiningRunning) {
      final p = state.total == 0 ? null : state.done / state.total;
      final stageLabel = switch (state.stage) {
        'mine' => 'Розділи: ${state.done} / ${state.total}',
        'aggregate' => 'Збір переможців голосування…',
        'select-chapters' => 'Вибір розділів…',
        _ => state.stage,
      };
      return _ProgressInfo(p, stageLabel);
    }
    if (state is TermExtractionDone) {
      return _ProgressInfo(1.0, 'У глосарії: ${state.glossaryWinners}');
    }
    return _ProgressInfo(0.0, null);
  }

  String? _summary(TermExtractionState state) {
    if (state is TermExtractionDone) {
      return 'Джерело: ${state.sourceLanguage} • '
          'Кандидатів ${state.candidatesDiscovered} → '
          'прийнято ${state.candidatesAccepted} → '
          'у глосарії ${state.glossaryWinners}';
    }
    if (state is TermExtractionFailed) {
      return 'Помилка на етапі ${state.stage}: ${state.error}';
    }
    if (state is TermExtractionCancelled) {
      return 'Скасовано користувачем';
    }
    return null;
  }
}

class _StageRow extends StatelessWidget {
  const _StageRow({
    required this.label,
    required this.progress,
    required this.sublabel,
  });

  final String label;
  final double? progress;
  final String? sublabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(label, style: theme.textTheme.bodyMedium),
                    ),
                    if (sublabel != null)
                      Text(
                        sublabel!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProgressInfo {
  _ProgressInfo(this.value, this.label);
  final double? value;
  final String? label;
}
