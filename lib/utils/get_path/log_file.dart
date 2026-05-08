import 'dart:io';

import 'get_base_path.dart';

Future<File> getLogFile() async {
  final logFileDir = await getAnxDocumentsPath();
  final String logFilePath =
      '$logFileDir${Platform.pathSeparator}ai_book_reader.log';
  final logFile = File(logFilePath);
  if (!logFile.existsSync()) {
    logFile.createSync();
  }
  return logFile;
}
