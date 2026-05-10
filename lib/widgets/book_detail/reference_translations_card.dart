import 'dart:io';

import 'package:ai_book_reader/l10n/generated/L10n.dart';
import 'package:ai_book_reader/models/reference_translation.dart';
import 'package:ai_book_reader/providers/reference_translations.dart';
import 'package:ai_book_reader/utils/log/common.dart';
import 'package:ai_book_reader/utils/toast/common.dart';
import 'package:ai_book_reader/widgets/common/container/filled_container.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ReferenceTranslationsCard extends ConsumerStatefulWidget {
  const ReferenceTranslationsCard({super.key, required this.bookId});

  final int bookId;

  @override
  ConsumerState<ReferenceTranslationsCard> createState() =>
      _ReferenceTranslationsCardState();
}

class _ReferenceTranslationsCardState
    extends ConsumerState<ReferenceTranslationsCard> {
  bool _dragging = false;

  Future<void> _pickFiles() async {
    AnxLog.info('ReferenceTranslationsCard: pick files invoked');
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['epub', 'fb2'],
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) {
      AnxLog.info('ReferenceTranslationsCard: pick cancelled');
      return;
    }
    final files = result.files
        .where((f) => f.path != null)
        .map((f) => File(f.path!))
        .toList();
    AnxLog.info('ReferenceTranslationsCard: picked ${files.length} files');
    await _ingest(files);
  }

  Future<void> _ingest(List<File> files) async {
    AnxLog.info('ReferenceTranslationsCard: _ingest with ${files.length} files');
    if (files.isEmpty) return;
    final notifier = ref.read(referenceTranslationsProvider(widget.bookId).notifier);
    final outcome = await notifier.addParts(files);
    if (!mounted) return;
    if (outcome.skippedFormat > 0) {
      AnxToast.show(L10n.of(context).referenceTranslationsUnsupportedFormat);
    }
    if (outcome.accepted > 0) {
      AnxToast.show(L10n.of(context)
          .referenceTranslationsAddedHint(outcome.accepted));
    }
  }

  Future<void> _confirmDelete(int id) async {
    final l10n = L10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.referenceTranslationsDeleteTitle),
        content: Text(l10n.referenceTranslationsDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.referenceTranslationsCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l10n.referenceTranslationsDeleteAction),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    await ref
        .read(referenceTranslationsProvider(widget.bookId).notifier)
        .deletePart(id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final asyncViews = ref.watch(referenceTranslationsProvider(widget.bookId));
    final theme = Theme.of(context);

    Widget header = Row(
      children: [
        Icon(Icons.translate_outlined,
            size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            l10n.referenceTranslationsTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );

    Widget hint = Text(
      l10n.referenceTranslationsHint,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );

    Widget body = asyncViews.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text('Error: $e'),
      ),
      data: (views) {
        if (views.isEmpty) {
          return _EmptyAddZone(onTap: _pickFiles);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final v in views)
              _PartRow(
                view: v,
                onDelete: () => _confirmDelete(v.row.id!),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.add),
                onPressed: _pickFiles,
                label: Text(l10n.referenceTranslationsAddAnother),
              ),
            ),
          ],
        );
      },
    );

    Widget content = FilledContainer(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 6),
          hint,
          const SizedBox(height: 10),
          body,
        ],
      ),
    );

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) {
        setState(() => _dragging = false);
        final files = detail.files
            .where((x) => x.path.isNotEmpty)
            .map((x) => File(x.path))
            .toList();
        _ingest(files);
      },
      child: Stack(
        children: [
          content,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(1),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                      color: theme.colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      l10n.referenceTranslationsDropHere,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyAddZone extends StatelessWidget {
  const _EmptyAddZone({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.outlineVariant,
            width: 1.4,
            style: BorderStyle.solid,
          ),
        ),
        child: Column(
          children: [
            Icon(Icons.add_circle_outline,
                size: 34, color: theme.colorScheme.primary),
            const SizedBox(height: 6),
            Text(
              l10n.referenceTranslationsAdd,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PartRow extends StatelessWidget {
  const _PartRow({required this.view, required this.onDelete});

  final ReferenceTranslationView view;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final progress = view.progress;

    Widget leading;
    String subtitle;
    Color subtitleColor = theme.colorScheme.onSurfaceVariant;

    switch (progress) {
      case RefIdle():
        leading = Icon(Icons.hourglass_empty, color: subtitleColor, size: 20);
        subtitle = _statusFromRow(l10n);
      case RefRunning(:final done, :final total):
        leading = SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2.2,
            value: total > 0 ? (done / total).clamp(0, 1).toDouble() : null,
          ),
        );
        subtitle = total > 0
            ? l10n.referenceTranslationsParsing(done, total)
            : l10n.referenceTranslationsPending;
      case RefDone(:final total):
        leading = Icon(Icons.check_circle,
            color: theme.colorScheme.primary, size: 20);
        subtitle = total > 0
            ? l10n.referenceTranslationsParsed(total)
            : _statusFromRow(l10n);
      case RefFailed(:final error):
        leading = Icon(Icons.error_outline,
            color: theme.colorScheme.error, size: 20);
        final raw = error.toString();
        subtitle =
            '${l10n.referenceTranslationsFailed}: ${raw.length > 80 ? '${raw.substring(0, 80)}…' : raw}';
        subtitleColor = theme.colorScheme.error;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  view.row.fileName,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: subtitleColor,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.referenceTranslationsDeleteAction,
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  String _statusFromRow(L10n l10n) {
    return switch (view.row.parsingStatus) {
      ReferenceParsingStatus.pending => l10n.referenceTranslationsPending,
      ReferenceParsingStatus.parsing =>
        l10n.referenceTranslationsParsing(0, 0),
      ReferenceParsingStatus.parsed => l10n.referenceTranslationsParsed(0),
      ReferenceParsingStatus.failed => l10n.referenceTranslationsFailed,
    };
  }
}
