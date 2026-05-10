import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ai_book_reader/service/pipeline/chapter_merger.dart';
import 'package:epub_decoder/epub_decoder.dart' as epub_decoder;
import 'package:html/parser.dart' as html_parser;
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Returns true if [filePath] points at an EPUB or FB2 file. Other formats are
/// not handled by the on-device pipeline.
bool isParseableBookFormat(String filePath) {
  final lower = filePath.toLowerCase();
  return lower.endsWith('.epub') || lower.endsWith('.fb2');
}

/// Reads an EPUB or FB2 file from disk and returns its chapters as a flat
/// `List<RawChapter>` (in reading order). Pure Dart — no WebView.
class BookFileParser {
  const BookFileParser._();

  static Future<List<RawChapter>> extractRawChapters(File file) async {
    final ext = p.extension(file.path).toLowerCase();
    final bytes = await file.readAsBytes();
    if (ext == '.fb2') {
      return _Fb2Parser.parse(bytes);
    }
    if (ext == '.epub') {
      return _EpubParser.parse(bytes);
    }
    throw UnsupportedError('Unsupported book format: $ext');
  }
}

/// Plain-Dart FB2 parser. FB2 is one XML document; chapters are `<section>`
/// elements anywhere under the main `<body>` (the body without
/// `name="notes"`). Sub-sections are flattened — `ChapterMerger` then
/// re-aggregates `1.1 / 1.2` numerically.
class _Fb2Parser {
  static List<RawChapter> parse(Uint8List bytes) {
    final text = _decode(bytes);
    final doc = XmlDocument.parse(text);

    final root = doc.rootElement;
    final bodies = root
        .findAllElements('body')
        .where((b) => (b.getAttribute('name') ?? '') != 'notes');
    if (bodies.isEmpty) return const [];

    final out = <RawChapter>[];
    for (final body in bodies) {
      final prologue = _collectDirectText(body, exclude: const {'section'});
      if (prologue.trim().isNotEmpty) {
        out.add(RawChapter(title: 'Prologue', content: prologue.trim()));
      }
      for (final section in body.findElements('section')) {
        _walkSection(section, out);
      }
    }
    return out;
  }

  static void _walkSection(XmlElement section, List<RawChapter> out) {
    final title = _extractTitle(section);
    final content = _collectDirectText(
      section,
      exclude: const {'section', 'title', 'epigraph', 'subtitle', 'image'},
    );
    if (title.isNotEmpty || content.trim().isNotEmpty) {
      out.add(RawChapter(
        title: title.isEmpty ? 'Section ${out.length + 1}' : title,
        content: content.trim(),
      ));
    }
    for (final sub in section.findElements('section')) {
      _walkSection(sub, out);
    }
  }

  static String _extractTitle(XmlElement section) {
    final titleEl = section.findElements('title').firstOrNull;
    if (titleEl == null) return '';
    final buf = StringBuffer();
    for (final p in titleEl.findElements('p')) {
      final s = p.innerText.trim();
      if (s.isNotEmpty) {
        if (buf.isNotEmpty) buf.write(' ');
        buf.write(s);
      }
    }
    return buf.toString();
  }

  static String _collectDirectText(
    XmlElement parent, {
    required Set<String> exclude,
  }) {
    final buf = StringBuffer();
    for (final child in parent.children) {
      if (child is! XmlElement) continue;
      if (exclude.contains(child.localName)) continue;
      final text = child.innerText.trim();
      if (text.isEmpty) continue;
      if (buf.isNotEmpty) buf.write('\n\n');
      buf.write(text);
    }
    return buf.toString();
  }

  static String _decode(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    final headLen = bytes.length < 200 ? bytes.length : 200;
    final head = String.fromCharCodes(bytes.sublist(0, headLen));
    final match =
        RegExp(r'''encoding\s*=\s*["']([^"']+)["']''').firstMatch(head);
    final declared = (match?.group(1) ?? 'utf-8').toLowerCase();
    if (declared == 'windows-1251' ||
        declared == 'cp1251' ||
        declared == 'cp-1251') {
      return _decodeCp1251(bytes);
    }
    if (declared == 'koi8-r' || declared == 'koi8r') {
      return latin1.decode(bytes, allowInvalid: true);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static String _decodeCp1251(Uint8List bytes) {
    final buf = StringBuffer();
    for (final b in bytes) {
      if (b < 0x80) {
        buf.writeCharCode(b);
      } else {
        buf.writeCharCode(_cp1251[b - 0x80]);
      }
    }
    return buf.toString();
  }

  static const List<int> _cp1251 = [
    0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021,
    0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
    0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0xFFFD, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
    0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7,
    0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
    0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7,
    0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
    0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417,
    0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, 0x041F,
    0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, 0x0427,
    0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, 0x042F,
    0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437,
    0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, 0x043F,
    0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, 0x0447,
    0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F,
  ];
}

/// EPUB parser via `package:epub_decoder` for spine extraction, then
/// `package:html` for plain-text per chapter. The package handles ZIP →
/// `META-INF/container.xml` → `.opf` → spine; we just consume `epub.sections`
/// in order.
class _EpubParser {
  static List<RawChapter> parse(Uint8List bytes) {
    final epub = epub_decoder.Epub.fromBytes(bytes);
    final out = <RawChapter>[];
    for (final section in epub.sections) {
      final raw = _extractFromXhtml(section.content.fileContent);
      if (raw == null) continue;
      out.add(raw);
    }
    return out;
  }

  static RawChapter? _extractFromXhtml(List<int> xhtmlBytes) {
    final bytes = xhtmlBytes is Uint8List
        ? xhtmlBytes
        : Uint8List.fromList(xhtmlBytes);
    final html = bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF
        ? utf8.decode(bytes.sublist(3), allowMalformed: true)
        : utf8.decode(bytes, allowMalformed: true);

    final doc = html_parser.parse(html);
    final body = doc.body;
    if (body == null) return null;

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
    if (title.isEmpty) {
      final t = doc.querySelector('title')?.text.trim();
      if (t != null && t.isNotEmpty) title = t;
    }

    final buf = StringBuffer();
    for (final node in body.querySelectorAll('p, div, li')) {
      final t = node.text.trim();
      if (t.isEmpty) continue;
      if (buf.isNotEmpty) buf.write('\n\n');
      buf.write(t);
    }
    final content = buf.toString().trim();
    if (title.isEmpty && content.isEmpty) return null;
    return RawChapter(title: title, content: content);
  }
}
