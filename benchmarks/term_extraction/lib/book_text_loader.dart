import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Loads the full plain-text body of a book. Accepts:
/// - a single `.epub` or `.txt` file, or
/// - a directory containing one or more `.epub` files (concatenated in
///   alphabetical order — Volume 01 first, then 02, etc.).
///
/// EPUB handling is intentionally naive: concatenates every HTML/XHTML file
/// inside the archive in alphabetical order with tags stripped. Good enough
/// for "does this term appear anywhere in the book" presence checks.
String loadBookText(String bookPath) {
  final type = FileSystemEntity.typeSync(bookPath);
  if (type == FileSystemEntityType.directory) {
    return _loadDirectory(bookPath);
  }
  final ext = p.extension(bookPath).toLowerCase();
  switch (ext) {
    case '.epub':
      return _loadEpub(bookPath);
    case '.txt':
      return File(bookPath).readAsStringSync();
    default:
      throw ArgumentError('Unsupported book extension: $ext (expected .epub or .txt)');
  }
}

String _loadDirectory(String dir) {
  final epubs = listEpubsInDirectory(dir);
  if (epubs.isEmpty) {
    throw StateError('No .epub files found in $dir');
  }
  final buf = StringBuffer();
  for (final f in epubs) {
    buf.writeln(_loadEpub(f.path));
  }
  return buf.toString();
}

/// Returns every `.epub` file directly inside [dir], sorted alphabetically by
/// path so that "Volume 01" → "Volume 02" → ... order is preserved.
List<File> listEpubsInDirectory(String dir) {
  return Directory(dir)
      .listSync()
      .whereType<File>()
      .where((f) => p.extension(f.path).toLowerCase() == '.epub')
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// Spine-aware EPUB → plain text. Mirrors what `tool/run_discovery_benchmark`
/// feeds into the Stage A isolate, so the filter and the algorithm see the
/// same words. Without this, the filter could think a term is "present in
/// the book" via a copyright page or back-matter while the spine-only
/// Discovery never gets to see it — leading to phantom ground-truth terms.
String _loadEpub(String epubPath) {
  final raws = parseEpubSpineRaw(File(epubPath));
  if (raws.isEmpty) {
    throw StateError('No spine entries with content in $epubPath');
  }
  final buf = StringBuffer();
  for (final entry in raws) {
    if (entry.title.isNotEmpty) {
      buf.writeln(entry.title);
    }
    buf.writeln(entry.content);
  }
  return buf.toString();
}

/// One chapter from an EPUB's spine, before merger.
class SpineChapter {
  const SpineChapter({required this.title, required this.content});
  final String title;
  final String content;
}

/// Pure-Dart EPUB spine extractor:
///   META-INF/container.xml → .opf path → manifest (id→href) + spine (idrefs)
/// → per-spine-entry XHTML body text (concatenated `<p>/<div>/<li>`) +
/// first h1/h2/h3 as title. Items outside the spine (cover.xhtml when not in
/// spine, TOC.ncx, etc.) are skipped.
///
/// Kept in this benchmark package — and not imported from the app — so the
/// benchmark stays runnable as a standalone Dart CLI. `tool/` in the repo
/// root has a deliberate duplicate that is fed straight into the Stage A
/// isolate; both files should evolve together.
List<SpineChapter> parseEpubSpineRaw(File file) {
  final bytes = file.readAsBytesSync();
  final archive = ZipDecoder().decodeBytes(bytes);

  final container = _findInArchive(archive, 'META-INF/container.xml');
  if (container == null) {
    throw StateError('container.xml not found in ${file.path}');
  }
  final containerDoc = XmlDocument.parse(_decodeUtf8(container.content));
  final rootfile = containerDoc.findAllElements('rootfile').firstOrNull;
  final opfPath = rootfile?.getAttribute('full-path');
  if (opfPath == null) {
    throw StateError('OPF rootfile path missing in container.xml');
  }

  final opfEntry = _findInArchive(archive, opfPath);
  if (opfEntry == null) {
    throw StateError('OPF $opfPath not found inside ${file.path}');
  }
  final opfDoc = XmlDocument.parse(_decodeUtf8(opfEntry.content));

  final manifest = <String, String>{};
  for (final item in opfDoc.findAllElements('item')) {
    final id = item.getAttribute('id');
    final href = item.getAttribute('href');
    if (id != null && href != null) manifest[id] = href;
  }

  final opfDir = p.posix.dirname(opfPath.replaceAll('\\', '/'));
  final out = <SpineChapter>[];
  for (final itemref in opfDoc.findAllElements('itemref')) {
    final idref = itemref.getAttribute('idref');
    if (idref == null) continue;
    final href = manifest[idref];
    if (href == null) continue;
    final fullPath = (opfDir.isEmpty || opfDir == '.')
        ? href
        : p.posix.join(opfDir, href);
    final entry = _findInArchive(archive, fullPath);
    if (entry == null) continue;
    final raw = _decodeUtf8(entry.content);
    final doc = html_parser.parse(raw);
    final body = doc.body;
    if (body == null) continue;

    String title = '';
    for (final sel in const ['h1', 'h2', 'h3']) {
      final el = body.querySelector(sel);
      if (el != null) {
        final t = el.text.trim();
        if (t.isNotEmpty) {
          title = t;
          break;
        }
      }
    }

    final buf = StringBuffer();
    for (final node in body.querySelectorAll('p, div, li')) {
      final t = node.text.trim();
      if (t.isEmpty) continue;
      if (buf.isNotEmpty) buf.write('\n\n');
      buf.write(t);
    }
    final content = buf.toString().trim();
    if (title.isEmpty && content.isEmpty) continue;
    out.add(SpineChapter(title: title, content: content));
  }
  return out;
}

ArchiveFile? _findInArchive(Archive archive, String path) {
  final norm = path.replaceAll('\\', '/');
  for (final f in archive.files) {
    if (!f.isFile) continue;
    if (f.name.replaceAll('\\', '/') == norm) return f;
  }
  return null;
}

String _decodeUtf8(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  return utf8.decode(bytes, allowMalformed: true);
}
