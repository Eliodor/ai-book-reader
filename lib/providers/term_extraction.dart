import 'dart:io';

import 'package:ai_book_reader/config/shared_preference_provider.dart';
import 'package:ai_book_reader/dao/glossary_term_variant_dao.dart';
import 'package:ai_book_reader/dao/mining_progress_dao.dart';
import 'package:ai_book_reader/service/pipeline/discovery/term_discovery_service.dart';
import 'package:ai_book_reader/service/pipeline/filter/term_filter_service.dart';
import 'package:ai_book_reader/service/pipeline/mining/term_mining_service.dart';
import 'package:ai_book_reader/service/pipeline/term_extraction_task_handler.dart';
import 'package:ai_book_reader/utils/log/common.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'term_extraction.g.dart';

/// Visible state for the term-extraction UI card. Three stages run in
/// sequence; each has its own progress tuple `(done, total)`.
sealed class TermExtractionState {
  const TermExtractionState();
}

class TermExtractionIdle extends TermExtractionState {
  const TermExtractionIdle();
}

class TermExtractionDiscoveryRunning extends TermExtractionState {
  const TermExtractionDiscoveryRunning({required this.stage});
  final String stage; // e.g. 'load-chapters', 'detect-language', 'discover'
}

class TermExtractionFilterRunning extends TermExtractionState {
  const TermExtractionFilterRunning({required this.done, required this.total});
  final int done;
  final int total;
}

class TermExtractionMiningRunning extends TermExtractionState {
  const TermExtractionMiningRunning({
    required this.done,
    required this.total,
    required this.stage,
  });
  final int done;
  final int total;
  final String stage; // 'mine', 'aggregate', ...
}

class TermExtractionDone extends TermExtractionState {
  const TermExtractionDone({
    required this.candidatesDiscovered,
    required this.candidatesAccepted,
    required this.glossaryWinners,
    required this.sourceLanguage,
  });
  final int candidatesDiscovered;
  final int candidatesAccepted;
  final int glossaryWinners;
  final String sourceLanguage;
}

class TermExtractionFailed extends TermExtractionState {
  const TermExtractionFailed({
    required this.stage,
    required this.error,
  });
  final String stage;
  final Object error;
}

class TermExtractionCancelled extends TermExtractionState {
  const TermExtractionCancelled();
}

@Riverpod(keepAlive: true)
class TermExtraction extends _$TermExtraction {
  @override
  TermExtractionState build(int bookId) => const TermExtractionIdle();

  bool _running = false;

  Future<void> start({
    required String fromLocale,
    required String toLocale,
  }) async {
    if (_running) return;
    _running = true;
    await _startForegroundService();

    try {
      state = const TermExtractionDiscoveryRunning(stage: 'load-chapters');
      _updateForegroundNotification('Пошук термінів: читання розділів…');
      final discovery = await termDiscoveryService.discoverIfNeeded(
        bookId: bookId,
        onStageChange: (s) {
          state = TermExtractionDiscoveryRunning(stage: s);
          _updateForegroundNotification('Пошук термінів: $s');
        },
      );

      var discovered = 0;
      var detectedLang = fromLocale;
      switch (discovery) {
        case DiscoveryCompleted(:final candidatesWritten, :final sourceLanguage):
          discovered = candidatesWritten;
          detectedLang = sourceLanguage;
        case DiscoverySkipped(:final reason):
          AnxLog.info('Term discovery skipped: $reason');
        case DiscoveryCancelled():
          state = const TermExtractionCancelled();
          return;
        case DiscoveryFailed(:final stage, :final error):
          state = TermExtractionFailed(stage: 'discovery/$stage', error: error);
          return;
      }

      state = const TermExtractionFilterRunning(done: 0, total: 0);
      _updateForegroundNotification('AI-фільтр: підготовка…');
      final filter = await termFilterService.filterIfNeeded(
        bookId: bookId,
        onProgress: (done, total) {
          state = TermExtractionFilterRunning(done: done, total: total);
          _updateForegroundNotification('AI-фільтр: $done / $total');
        },
      );
      var acceptedTotal = 0;
      switch (filter) {
        case FilterCompleted(:final accepted, :final uncertain):
          // Include uncertain in the "accepted" tally for UI purposes;
          // Stage C still mines both buckets.
          acceptedTotal = accepted + uncertain;
        case FilterSkipped(:final reason):
          AnxLog.info('Term filter skipped: $reason');
        case FilterCancelled():
          state = const TermExtractionCancelled();
          return;
        case FilterFailed(:final error):
          state = TermExtractionFailed(stage: 'filter', error: error);
          return;
      }

      state = const TermExtractionMiningRunning(
        done: 0,
        total: 0,
        stage: 'mine',
      );
      _updateForegroundNotification('Майнинг: підготовка…');
      final mining = await termMiningService.mineIfNeeded(
        bookId: bookId,
        fromLocale: detectedLang,
        toLocale: toLocale,
        onProgress: (done, total) {
          state = TermExtractionMiningRunning(
            done: done,
            total: total,
            stage: 'mine',
          );
          _updateForegroundNotification('Майнинг: розділів $done / $total');
        },
        onStageChange: (s) {
          final cur = state;
          if (cur is TermExtractionMiningRunning) {
            state = TermExtractionMiningRunning(
              done: cur.done,
              total: cur.total,
              stage: s,
            );
          }
          _updateForegroundNotification('Майнинг: $s');
        },
      );

      var winners = 0;
      switch (mining) {
        case MiningCompleted(:final glossaryWinners):
          winners = glossaryWinners;
        case MiningSkipped(:final reason):
          AnxLog.info('Term mining skipped: $reason');
        case MiningCancelled():
          state = const TermExtractionCancelled();
          return;
        case MiningFailed(:final stage, :final error):
          state = TermExtractionFailed(stage: 'mining/$stage', error: error);
          return;
      }

      state = TermExtractionDone(
        candidatesDiscovered: discovered,
        candidatesAccepted: acceptedTotal,
        glossaryWinners: winners,
        sourceLanguage: detectedLang,
      );
    } catch (e, st) {
      AnxLog.severe('Term extraction failed: $e\n$st');
      state = TermExtractionFailed(stage: 'unknown', error: e);
    } finally {
      _running = false;
      await _stopForegroundService();
    }
  }

  void cancel() {
    termDiscoveryService.cancel();
    termFilterService.cancel();
    termMiningService.cancel();
  }

  Future<void> reset() async {
    cancel();
    await termDiscoveryService.resetForBook(bookId);
    await glossaryTermVariantDao.deleteByBookId(bookId);
    await miningProgressDao.deleteByBookId(bookId);
    state = const TermExtractionIdle();
  }

  Future<void> _startForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'term_extraction_channel',
          channelName: 'Term extraction',
          channelDescription:
              'Background work for glossary discovery, AI filter and mining.',
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: false,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );
      final permission =
          await FlutterForegroundTask.checkNotificationPermission();
      if (permission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      final running = await FlutterForegroundTask.isRunningService;
      if (running) {
        await FlutterForegroundTask.restartService();
      } else {
        await FlutterForegroundTask.startService(
          serviceId: 0x7E70, // arbitrary, must be stable per service kind.
          notificationTitle: 'Витяг глосарію',
          notificationText: 'Підготовка…',
          callback: termExtractionTaskCallback,
        );
      }
    } catch (e, st) {
      AnxLog.warning('Foreground service init failed: $e\n$st');
    }
  }

  void _updateForegroundNotification(String text) {
    if (!Platform.isAndroid) return;
    try {
      FlutterForegroundTask.updateService(
        notificationTitle: 'Витяг глосарію',
        notificationText: text,
      );
    } catch (_) {
      // ignored — service may not have started, fine to no-op.
    }
  }

  Future<void> _stopForegroundService() async {
    if (!Platform.isAndroid) return;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {
      // ignored
    }
  }
}

/// Sensible defaults for the from/to locales that the UI uses if the user
/// hasn't picked anything explicitly.
String currentToLocale() {
  final prefsLocale = Prefs().locale?.languageCode;
  if (prefsLocale != null && prefsLocale.isNotEmpty) return prefsLocale;
  return defaultTargetLocale;
}

const String defaultTargetLocale = 'en';
