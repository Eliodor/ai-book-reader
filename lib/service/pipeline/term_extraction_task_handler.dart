import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Minimal foreground task handler used to keep the Android process alive
/// while the term-extraction pipeline runs in the main isolate.
///
/// We don't move pipeline work to the task isolate — DB, Riverpod and the
/// langchain HTTP stack all live in the main isolate. The service exists to
/// (a) hold a wake-lock so the OS won't kill us under doze / screen-off, and
/// (b) show a persistent notification so the user knows work is happening.
@pragma('vm:entry-point')
void termExtractionTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_TermExtractionTaskHandler());
}

class _TermExtractionTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
