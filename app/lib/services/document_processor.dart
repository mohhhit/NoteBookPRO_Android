import 'dart:io';
import 'package:read_pdf_text/read_pdf_text.dart';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

List<String> chunkTextTask(Map<String, String> data) {
  final processor = DocumentProcessor();
  return processor.chunkText(data['content']!, sourceFilename: data['virtualFilename']);
}

class DocumentProcessor {
  final List<String> supportedFormats = ['.pdf', '.txt', '.docx'];

  Future<Map<String, dynamic>> processFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('File not found: $path');
    }

    final filename = file.uri.pathSegments.last;
    final suffix = _getExtension(filename);

    String content = '';
    String publicationYear = '0000';
    String virtualFilename = filename;

    if (suffix == '.pdf') {
      content = await _extractPdf(file);
      final frontMatter = content.length > 2000 ? content.substring(0, 2000) : content;
      publicationYear = _detectYear(frontMatter);
      virtualFilename = '[$publicationYear] $filename';
    } else if (suffix == '.txt') {
      content = await _extractTxt(file);
    } else if (suffix == '.docx') {
      content = await _extractDocx(file);
    } else {
      throw Exception('Unsupported file format: $suffix');
    }

    return {
      'filename': filename,
      'virtual_filename': virtualFilename,
      'publication_year': publicationYear,
      'path': path,
      'content': content,
      'format': suffix,
    };
  }

  String _getExtension(String filename) {
    final idx = filename.lastIndexOf('.');
    if (idx < 0) return '';
    return filename.substring(idx).toLowerCase();
  }

  Future<String> _extractPdf(File file) async {
    if (await file.length() == 0) {
      throw Exception('PDF is empty (0 bytes)');
    }

    try {
      final text = await ReadPdfText.getPDFtext(file.path);
      return _cleanText(text);
    } catch (e) {
      throw Exception('Could not extract text from PDF: $e');
    }
  }

  Future<String> _extractTxt(File file) async {
    try {
      final text = await file.readAsString();
      return _cleanText(text);
    } catch (e) {
      // Fallback encoding if utf-8 fails
      final bytes = await file.readAsBytes();
      final text = String.fromCharCodes(bytes);
      return _cleanText(text);
    }
  }

  Future<String> _extractDocx(File file) async {
    try {
      final bytes = await file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);
      
      for (final file in archive) {
        if (file.name == 'word/document.xml') {
          final content = file.content as List<int>;
          final xmlString = String.fromCharCodes(content);
          final document = XmlDocument.parse(xmlString);
          
          final paragraphs = document.findAllElements('w:p');
          final textBuffer = StringBuffer();
          
          for (final p in paragraphs) {
            final texts = p.findAllElements('w:t');
            for (final t in texts) {
              textBuffer.write(t.innerText);
            }
            textBuffer.writeln();
          }
          
          return _cleanText(textBuffer.toString());
        }
      }
      return '';
    } catch (e) {
      throw Exception('Could not extract text from DOCX: $e');
    }
  }

  String _cleanText(String text) {
    // Normalize line endings
    var t = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    
    // Fix hyphenated word breaks at end of line (e.g. "lightweig-\nht" -> "lightweight")
    t = t.replaceAll(RegExp(r'-\n\s*'), '');
    
    // Join lines that are part of the same paragraph (single newline to space)
    t = t.replaceAll(RegExp(r'(?<!\n)\n(?!\n)'), ' ');
    
    // Keep paragraph boundaries; collapse inner spaces/tabs only.
    t = t.replaceAll(RegExp(r'[ \t]+'), ' ');
    
    // Keep common punctuation and line breaks, strip noisy symbols.
    t = t.replaceAll(RegExp(r"""[^\w\s.,!?;:()\-\'"\n/]+"""), '');
    
    // Remove excessive blank lines
    t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    
    return t.trim();
  }

  String _detectYear(String text) {
    final matches = RegExp(r'(?:19|20)\d{2}').allMatches(text);
    if (matches.isEmpty) return '0000';
    
    int maxYear = 0;
    for (final match in matches) {
      final y = int.tryParse(match.group(0) ?? '0') ?? 0;
      if (y > maxYear && y <= DateTime.now().year) {
        maxYear = y;
      }
    }
    
    return maxYear > 0 ? maxYear.toString() : '0000';
  }

  List<String> chunkText(
    String text, {
    int chunkSize = 2000,
    int overlap = 200,
    bool semantic = true,
    String? sourceFilename,
  }) {
    if (text.trim().isEmpty) return [];

    // Split text cleanly by paragraph and sentence boundaries
    final paragraphs = text.split(RegExp(r'\n\s*\n'));
    final chunks = <String>[];
    var currentChunk = StringBuffer();
    var overlapBuffer = <String>[];

    void emitChunk() {
      final chunkStr = currentChunk.toString().trim();
      if (chunkStr.isNotEmpty) {
        chunks.add(chunkStr);
      }
      currentChunk.clear();
      if (overlapBuffer.isNotEmpty) {
        currentChunk.write(overlapBuffer.join(' '));
        currentChunk.write(' ');
      }
    }

    for (final para in paragraphs) {
      final trimmedPara = para.trim();
      if (trimmedPara.isEmpty) continue;

      // If entire paragraph fits in the current chunk
      if (currentChunk.length + trimmedPara.length + 1 <= chunkSize) {
        if (currentChunk.isNotEmpty) currentChunk.write('\n\n');
        currentChunk.write(trimmedPara);

        // Keep last 1-2 sentences for overlap
        final sList = trimmedPara.split(RegExp(r'(?<=[.!?])\s+'));
        if (sList.isNotEmpty) {
          overlapBuffer = sList.length > 2 ? sList.sublist(sList.length - 2) : sList;
        }
      } else {
        // Break paragraph cleanly by sentence
        final sentences = trimmedPara.split(RegExp(r'(?<=[.!?])\s+'));
        for (final sentence in sentences) {
          final sTrimmed = sentence.trim();
          if (sTrimmed.isEmpty) continue;

          if (currentChunk.length + sTrimmed.length + 1 > chunkSize && currentChunk.isNotEmpty) {
            emitChunk();
          }

          if (currentChunk.isNotEmpty) currentChunk.write(' ');
          currentChunk.write(sTrimmed);

          // Maintain trailing sentences for next chunk's overlap
          overlapBuffer.add(sTrimmed);
          if (overlapBuffer.length > 2) {
            overlapBuffer.removeAt(0);
          }
        }
      }
    }

    if (currentChunk.isNotEmpty) {
      final lastStr = currentChunk.toString().trim();
      if (lastStr.isNotEmpty) {
        chunks.add(lastStr);
      }
    }

    return chunks.where((c) => c.length > 40).toList();
  }
}
