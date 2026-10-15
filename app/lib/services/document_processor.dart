import 'dart:io';
import 'package:read_pdf_text/read_pdf_text.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

List<String> chunkTextTask(Map<String, String> data) {
  final processor = DocumentProcessor();
  return processor.chunkText(
    data['content']!,
    sourceFilename: data['virtualFilename'],
    chunkSize: 700,
    overlap: 120,
  );
}

class DocumentProcessor {
  final List<String> supportedFormats = ['.pdf', '.txt', '.docx'];

  Future<Map<String, dynamic>> processFile(
    String path, {
    void Function(int current, int total)? onProgress,
    void Function(String message)? onStatus,
  }) async {
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
      content = await _extractPdf(file, onProgress: onProgress, onStatus: onStatus);
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

  Future<String> _extractPdf(
    File file, {
    void Function(int current, int total)? onProgress,
    void Function(String message)? onStatus,
  }) async {
    if (await file.length() == 0) {
      throw Exception('PDF is empty (0 bytes)');
    }

    String extracted = '';

    // Primary Engine: Native ReadPdfText platform channel (faster for standard digital PDFs)
    try {
      final text = await ReadPdfText.getPDFtext(file.path);
      extracted = _cleanText(text);
    } catch (_) {}

    // Fallback Engine 1: Pure-Dart Syncfusion PDF Engine
    // Activates if ReadPdfText returns empty or fails (e.g. OpenType GSUB Type 7 lookup tables,
    // Calibri font encoding, or complex subset CMap tables).
    if (extracted.trim().isEmpty) {
      try {
        final bytes = await file.readAsBytes();
        final document = PdfDocument(inputBytes: bytes);
        final syncText = PdfTextExtractor(document).extractText();
        document.dispose();
        extracted = _cleanText(syncText);
      } catch (_) {}
    }

    // Fallback Engine 2: On-Device Google ML Kit OCR + Native PdfRenderer
    // Activates if the PDF contains scanned / image-only pages where no digital character stream exists
    // (extracted text is empty or less than 50 characters).
    if (extracted.trim().length < 50) {
      try {
        onStatus?.call('Image-based PDF detected. Initializing on-device OCR...');
        final ocrText = await _ocrScannedPdf(
          file,
          onProgress: onProgress,
          onStatus: onStatus,
        );
        if (ocrText.trim().isNotEmpty) {
          extracted = ocrText;
        }
      } catch (e) {
        print('[DocumentProcessor] OCR extraction fallback failed: $e');
      }
    }

    return extracted;
  }

  /// On-Device OCR Pipeline for Scanned / Image-Based PDFs:
  /// Uses pdfx (backed by native android.graphics.pdf.PdfRenderer on Android) to rasterize pages
  /// and Google ML Kit Text Recognition to perform hardware-accelerated on-device OCR.
  /// High memory efficiency: renders and processes one page at a time, immediately deleting the
  /// temporary raster bitmap so memory and storage usage stay constant even for large textbooks.
  Future<String> _ocrScannedPdf(
    File file, {
    void Function(int current, int total)? onProgress,
    void Function(String message)? onStatus,
  }) async {
    // Only attempt on Android or iOS where ML Kit native models run
    if (!Platform.isAndroid && !Platform.isIOS) {
      print('[DocumentProcessor] ML Kit OCR is only supported on mobile platforms (Android/iOS). Skipping OCR on ${Platform.operatingSystem}.');
      return '';
    }

    pdfx.PdfDocument? document;
    TextRecognizer? textRecognizer;
    Directory? tempOcrDir;

    try {
      onStatus?.call('Opening scanned PDF for OCR...');
      document = await pdfx.PdfDocument.openFile(file.path);
      final totalPages = document.pagesCount;
      if (totalPages == 0) return '';

      textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final sysTemp = Directory.systemTemp;
      tempOcrDir = await sysTemp.createTemp('notebookpro_ocr_');

      final buffer = StringBuffer();

      for (int pageNum = 1; pageNum <= totalPages; pageNum++) {
        onProgress?.call(pageNum, totalPages);
        onStatus?.call('OCR scanning page $pageNum of $totalPages...');

        pdfx.PdfPage? page;
        try {
          page = await document.getPage(pageNum);

          // Calculate render scale: standard 72-dpi page scaled ~2x produces crisp 144-200 dpi text.
          // Cap maximum dimension to 2400 to prevent out-of-memory spikes on low-RAM devices.
          double scale = 2.0;
          if (page.width * scale > 2400) {
            scale = 2400 / page.width;
          }
          final renderWidth = page.width * scale;
          final renderHeight = page.height * scale;

          final pageImage = await page.render(
            width: renderWidth,
            height: renderHeight,
            format: pdfx.PdfPageImageFormat.jpeg,
            backgroundColor: '#FFFFFF',
            quality: 85,
          );

          if (pageImage != null && pageImage.bytes.isNotEmpty) {
            final tempPath = '${tempOcrDir.path}/page_$pageNum.jpg';
            final tempFile = File(tempPath);
            await tempFile.writeAsBytes(pageImage.bytes, flush: true);

            try {
              final inputImage = InputImage.fromFilePath(tempPath);
              final recognizedText = await textRecognizer.processImage(inputImage);
              final text = recognizedText.text.trim();
              if (text.isNotEmpty) {
                buffer.writeln(text);
                buffer.writeln(); // Separate pages with empty lines
              }
            } finally {
              // Delete each temp image immediately to keep disk footprint near 0
              if (await tempFile.exists()) {
                await tempFile.delete();
              }
            }
          }
        } catch (pageErr) {
          print('[DocumentProcessor] Warning: failed to OCR page $pageNum: $pageErr');
        } finally {
          await page?.close();
        }

        // Keep UI thread responsive
        if (pageNum % 5 == 0) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }

      return _cleanText(buffer.toString());
    } catch (e) {
      print('[DocumentProcessor] Error during scanned PDF OCR: $e');
      rethrow;
    } finally {
      await document?.close();
      await textRecognizer?.close();
      if (tempOcrDir != null && await tempOcrDir.exists()) {
        try {
          await tempOcrDir.delete(recursive: true);
        } catch (_) {}
      }
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

  static final RegExp _chapterPattern = RegExp(
    r'^(?:#\s+)?(?:chapter|part|module|unit)\s+(?:[0-9ivxlcdm]+)[:\s\.\-–—]+([^\n]+)',
    caseSensitive: false,
  );

  static final RegExp _markdownHeaderPattern = RegExp(
    r'^(#{1,3})\s+([^\n]+)$',
  );

  static final RegExp _numberedSectionPattern = RegExp(
    r'^(?:section\s+)?(\d+\.\d+(?:\.\d+)?)\s*[:\s\.\-–—]+\s*([^\n]+)',
    caseSensitive: false,
  );

  /// Detects whether a paragraph is a textbook chapter or section heading.
  static String? _detectHeading(String para) {
    final trimmed = para.trim();
    if (trimmed.isEmpty || trimmed.length > 90) return null;
    if (trimmed.contains('\n')) {
      final firstLine = trimmed.split('\n').first.trim();
      if (firstLine.length < 4 || firstLine.length > 90) return null;
      return _detectSingleLineHeading(firstLine);
    }
    return _detectSingleLineHeading(trimmed);
  }

  static String? _detectSingleLineHeading(String line) {
    final t = line.trim();
    if (t.length < 4 || t.length > 85) return null;

    // Chapter or major module
    final chapMatch = _chapterPattern.firstMatch(t);
    if (chapMatch != null) {
      return t.replaceAll(RegExp(r'^#+\s*'), '').trim();
    }

    // Markdown header
    final mdMatch = _markdownHeaderPattern.firstMatch(t);
    if (mdMatch != null) {
      return mdMatch.group(2)!.trim();
    }

    // Numbered section e.g. 4.2 Storage Formats
    final numMatch = _numberedSectionPattern.firstMatch(t);
    if (numMatch != null) {
      return t.trim();
    }

    // Short prominent title lines:
    // Starts with uppercase, does not end in period, comma, or colon,
    // and has title casing / capital density.
    if (RegExp(r'^[A-Z0-9]').hasMatch(t) &&
        !RegExp(r'[.,:;?!)]\s*$').hasMatch(t) &&
        t.split(RegExp(r'\s+')).length >= 2 &&
        t.split(RegExp(r'\s+')).length <= 9) {
      final words = t.split(RegExp(r'\s+'));
      final capWords = words.where((w) => w.isNotEmpty && RegExp(r'^[A-Z]').hasMatch(w)).length;
      if (capWords >= words.length * 0.6) {
        return t;
      }
    }

    return null;
  }

  /// Extracts section breadcrumb from a chunk if present.
  static String? extractBreadcrumb(String chunk) {
    final m = RegExp(r'^\[Section:\s*([^\]\n]+)\]', caseSensitive: false).firstMatch(chunk.trim());
    return m?.group(1)?.trim();
  }

  List<String> chunkText(
    String text, {
    int chunkSize = 700,
    int overlap = 120,
    bool semantic = true,
    String? sourceFilename,
  }) {
    if (text.trim().isEmpty) return [];

    // Split text cleanly by paragraph and sentence boundaries
    final paragraphs = text.split(RegExp(r'\n\s*\n'));
    final chunks = <String>[];
    var currentChunk = StringBuffer();
    var overlapBuffer = <String>[];
    String currentChapter = '';
    String currentSection = '';

    String buildBreadcrumb() {
      if (currentChapter.isNotEmpty && currentSection.isNotEmpty) {
        return '$currentChapter > $currentSection';
      } else if (currentChapter.isNotEmpty) {
        return currentChapter;
      } else if (currentSection.isNotEmpty) {
        return currentSection;
      }
      return '';
    }

    final docPrefix = (sourceFilename != null && sourceFilename.isNotEmpty)
        ? 'Source Document: $sourceFilename\n---\n'
        : '';

    void emitChunk() {
      final chunkStr = currentChunk.toString().trim();
      if (chunkStr.isNotEmpty) {
        final breadcrumb = buildBreadcrumb();
        if (breadcrumb.isNotEmpty && !chunkStr.startsWith('[Section:')) {
          chunks.add('$docPrefix[Section: $breadcrumb]\n$chunkStr');
        } else {
          chunks.add('$docPrefix$chunkStr');
        }
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

      // Track active chapter or section heading for hierarchical breadcrumbs
      final heading = _detectHeading(trimmedPara);
      if (heading != null) {
        if (_chapterPattern.hasMatch(heading) ||
            heading.toLowerCase().startsWith('chapter') ||
            heading.toLowerCase().startsWith('part')) {
          currentChapter = heading;
          currentSection = '';
        } else {
          currentSection = heading;
        }
      }

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
      final breadcrumb = buildBreadcrumb();
      final lastStr = currentChunk.toString().trim();
      if (lastStr.isNotEmpty) {
        if (breadcrumb.isNotEmpty && !lastStr.startsWith('[Section:')) {
          chunks.add('$docPrefix[Section: $breadcrumb]\n$lastStr');
        } else {
          chunks.add('$docPrefix$lastStr');
        }
      }
    }

    return chunks.where((c) => c.length > 40).toList();
  }
}
