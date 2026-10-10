import 'dart:io';
import 'package:flutter/foundation.dart';
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
    final rawChunks = _recursiveSplit(text, chunkSize, overlap);
    return rawChunks.map((chunk) => chunk.trim()).toList();
  }

  List<String> _recursiveSplit(String text, int chunkSize, int overlap) {
    final separators = ["\n\n", "\n", ".", "?", "!", " ", ""];
    
    List<String> splitText(String txt, int sepIndex) {
      if (txt.length <= chunkSize) return [txt];
      if (sepIndex >= separators.length) return _simpleChunk(txt, chunkSize, overlap);
      
      final separator = separators[sepIndex];
      final parts = txt.split(separator);
      
      if (parts.length == 1) {
        return splitText(txt, sepIndex + 1);
      }
      
      final chunks = <String>[];
      var currentChunk = '';
      
      for (final part in parts) {
        final nextChunk = currentChunk.isEmpty ? part : currentChunk + separator + part;
        if (nextChunk.length <= chunkSize) {
          currentChunk = nextChunk;
        } else {
          if (currentChunk.isNotEmpty) {
            chunks.add(currentChunk);
            // Overlap logic is hard in strict recursion, so we just fall back 
            // to a simpler approach or accept slight truncation in boundaries.
            // For a true Langchain replica, we merge chunks while accounting for overlap.
          }
          currentChunk = part;
        }
      }
      
      if (currentChunk.isNotEmpty) {
        chunks.add(currentChunk);
      }
      
      // If any resulting chunk is still too big, split it further
      final finalChunks = <String>[];
      for (final c in chunks) {
        if (c.length > chunkSize) {
          finalChunks.addAll(splitText(c, sepIndex + 1));
        } else {
          finalChunks.add(c);
        }
      }
      
      return finalChunks;
    }
    
    return splitText(text, 0);
  }

  List<String> _simpleChunk(String text, int chunkSize, int overlap) {
    final chunks = <String>[];
    int start = 0;
    
    while (start < text.length) {
      int end = start + chunkSize;
      String chunk = text.substring(start, end > text.length ? text.length : end);
      
      if (end < text.length) {
        final lastPeriod = chunk.lastIndexOf('.');
        final lastNewline = chunk.lastIndexOf('\n');
        final breakPoint = lastPeriod > lastNewline ? lastPeriod : lastNewline;
        
        if (breakPoint > chunkSize * 0.5) {
          chunk = chunk.substring(0, breakPoint + 1);
          end = start + breakPoint + 1;
        }
      }
      
      chunks.add(chunk.trim());
      start = end - overlap;
      if (start < 0) start = 0; // sanity
    }
    
    return chunks;
  }
}
