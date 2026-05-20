// One-shot: parses every .epub in data/solo-leveling/book/ via the same
// spine-aware loader as the in-app pipeline (book_text_loader.dart -> mirrors
// lib/service/pipeline/book_file_parser.dart) and writes one plain-text file
// per volume to data/solo-leveling/cache/text/. Used to feed parallel
// term-extraction agents.
//
// Run with:
//   dart run tool/extract_volumes_text.dart

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:term_extraction_benchmark/book_text_loader.dart';

void main() {
  final root = File(Platform.script.toFilePath()).parent.parent;
  final bookDir = Directory(p.join(root.path, 'data', 'solo-leveling', 'book'));
  if (!bookDir.existsSync()) {
    stderr.writeln('Book directory not found: ${bookDir.path}');
    exitCode = 1;
    return;
  }

  final outDir = Directory(p.join(root.path, 'data', 'solo-leveling', 'cache', 'text'))
    ..createSync(recursive: true);

  final epubs = listEpubsInDirectory(bookDir.path);
  if (epubs.isEmpty) {
    stderr.writeln('No .epub files found in ${bookDir.path}');
    exitCode = 1;
    return;
  }

  stdout.writeln('Found ${epubs.length} volumes.');

  for (var i = 0; i < epubs.length; i++) {
    final epub = epubs[i];
    final volumeNo = (i + 1).toString().padLeft(2, '0');
    final outFile = File(p.join(outDir.path, 'volume_$volumeNo.txt'));
    stdout.writeln('[$volumeNo] Parsing ${p.basename(epub.path)} ...');

    final chapters = parseEpubSpineRaw(epub);
    final buf = StringBuffer();
    for (final ch in chapters) {
      if (ch.title.isNotEmpty) {
        buf.writeln('## ${ch.title}');
        buf.writeln();
      }
      buf.writeln(ch.content);
      buf.writeln();
    }
    outFile.writeAsStringSync(buf.toString());
    stdout.writeln(
        '       wrote ${outFile.path}  (${chapters.length} spine entries, ${buf.length} chars)');
  }

  stdout.writeln('Done.');
}
