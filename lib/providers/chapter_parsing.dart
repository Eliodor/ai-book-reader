import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'chapter_parsing.g.dart';

/// Progress of the one-shot chapter-parsing pass that fills `tb_source_chapters`
/// the first time a book is opened.
sealed class ChapterParsingState {
  const ChapterParsingState();
}

class ChapterParsingIdle extends ChapterParsingState {
  const ChapterParsingIdle();
}

class ChapterParsingRunning extends ChapterParsingState {
  const ChapterParsingRunning({required this.done, required this.total});
  final int done;
  final int total;
}

class ChapterParsingDone extends ChapterParsingState {
  const ChapterParsingDone({required this.total});
  final int total;
}

class ChapterParsingFailed extends ChapterParsingState {
  const ChapterParsingFailed({
    required this.error,
    required this.done,
    required this.total,
  });
  final Object error;
  final int done;
  final int total;
}

@Riverpod(keepAlive: true)
class ChapterParsing extends _$ChapterParsing {
  @override
  ChapterParsingState build(int bookId) {
    return const ChapterParsingIdle();
  }

  void start(int total) {
    state = ChapterParsingRunning(done: 0, total: total);
  }

  void tick(int done, int total) {
    state = ChapterParsingRunning(done: done, total: total);
  }

  void markDone(int total) {
    state = ChapterParsingDone(total: total);
  }

  void fail(Object error, {required int done, required int total}) {
    state = ChapterParsingFailed(error: error, done: done, total: total);
  }

  void reset() {
    state = const ChapterParsingIdle();
  }
}
