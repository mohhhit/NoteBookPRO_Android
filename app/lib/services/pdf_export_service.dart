import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import '../models/studio_models.dart';
import 'studio_service.dart';

class PdfExportService {
  /// Converts plain text or Quill Delta JSON into formatted text for PDF.
  static String quillOrPlainToText(String content) {
    if (content.isEmpty) return '';
    final stripped = content.trim();
    if (!stripped.startsWith('{') && !stripped.startsWith('[')) {
      return stripped;
    }

    try {
      final parsed = jsonDecode(stripped);
      List ops = [];
      if (parsed is Map && parsed['ops'] is List) {
        ops = parsed['ops'];
      } else if (parsed is List) {
        ops = parsed;
      } else {
        return stripped;
      }

      final buffer = StringBuffer();
      for (final op in ops) {
        if (op is Map && op['insert'] != null) {
          final insert = op['insert'];
          if (insert is String) {
            final attrs = op['attributes'] as Map?;
            if (attrs != null && attrs['bold'] == true) {
              buffer.write('**$insert**');
            } else if (attrs != null && attrs['italic'] == true) {
              buffer.write('*$insert*');
            } else {
              buffer.write(insert);
            }
          }
        }
      }
      final result = buffer.toString().trim();
      return result.isNotEmpty ? result : stripped;
    } catch (_) {
      return stripped;
    }
  }

  /// Sanitizes string into a filesystem-safe PDF filename.
  static String safePdfFilename(String name) {
    var base = name.trim().replaceAll(RegExp(r'\s+'), '_');
    base = base.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '');
    if (base.isEmpty) {
      base = 'notebookpro_export';
    }
    if (base.toLowerCase().endsWith('.pdf')) {
      return base;
    }
    return '$base.pdf';
  }

  /// Sets up universal header & footer template stamped on every page.
  static void _setupHeaderAndFooter(
    PdfDocument document, {
    required String spaceName,
    required String documentTitle,
  }) {
    final pageSize = document.pageSettings.size;
    final margin = document.pageSettings.margins.left;
    final usableWidth = pageSize.width - (margin * 2);

    // Top Header Template
    final header = PdfPageTemplateElement(Rect.fromLTWH(0, 0, pageSize.width, 32));
    header.graphics.drawString(
      'NoteBookPRO  •  $spaceName',
      PdfStandardFont(PdfFontFamily.helvetica, 8, style: PdfFontStyle.bold),
      brush: PdfSolidBrush(PdfColor(113, 128, 150)),
      bounds: Rect.fromLTWH(margin, 10, usableWidth, 18),
    );
    header.graphics.drawLine(
      PdfPen(PdfColor(226, 232, 240), width: 0.6),
      Offset(margin, 26),
      Offset(pageSize.width - margin, 26),
    );
    document.template.top = header;

    // Bottom Footer Template
    final footer = PdfPageTemplateElement(Rect.fromLTWH(0, 0, pageSize.width, 32));
    footer.graphics.drawLine(
      PdfPen(PdfColor(226, 232, 240), width: 0.6),
      Offset(margin, 6),
      Offset(pageSize.width - margin, 6),
    );
    footer.graphics.drawString(
      'Exported from NoteBookPRO Offline',
      PdfStandardFont(PdfFontFamily.helvetica, 8, style: PdfFontStyle.italic),
      brush: PdfSolidBrush(PdfColor(140, 150, 160)),
      bounds: Rect.fromLTWH(margin, 12, usableWidth, 18),
    );
    document.template.bottom = footer;
  }

  static bool _isTableDivider(String line) {
    final trimmed = line.trim();
    if (!trimmed.contains('|')) return false;
    final cells = trimmed.replaceAll(RegExp(r'^\||\|$'), '').split('|');
    if (cells.length < 2) return false;
    return cells.every((c) => RegExp(r'^\s*:?-{3,}:?\s*$').hasMatch(c));
  }

  static bool _isTableRow(String line) {
    final trimmed = line.trim();
    return trimmed.startsWith('|') && trimmed.endsWith('|') && trimmed.length > 2;
  }

  static List<String> _extractTableCells(String line) {
    return line
        .trim()
        .replaceAll(RegExp(r'^\||\|$'), '')
        .split('|')
        .map((c) => c.replaceAll('**', '').trim())
        .toList();
  }

  static String _normalizeEntryBodyForExport(NotebookEntry entry, String bodyText) {
    if (entry.sourceType != 'chat') return bodyText;
    final qa = StudioService.extractChatQa(bodyText);
    if (qa == null) return bodyText;

    final q = qa['question'] ?? '';
    final a = qa['answer'] ?? '';
    if (q.isEmpty || a.isEmpty) return bodyText;

    final t = entry.title.trim().toLowerCase();
    final qLower = q.trim().toLowerCase();
    if (t == qLower || (t.length >= 15 && qLower.startsWith(t)) || (qLower.length >= 15 && t.startsWith(qLower))) {
      return a;
    }
    return bodyText;
  }

  /// Draws markdown/plain text content block-by-block with rich typography and layout.
  static void _renderMarkdownContent({
    required PdfDocument document,
    required PdfPage initialPage,
    required String markdownText,
    required double startY,
  }) {
    PdfPage currentPage = initialPage;
    var clientSize = currentPage.getClientSize();
    final usableWidth = clientSize.width;
    double cursorY = startY;

    // Clean citations, LaTeX math, and strip any trailing passages dump
    final cleaned = StudioService.formatChatAnswer(markdownText);
    final lines = cleaned.replaceAll('\r\n', '\n').split('\n');

    final bodyFont = PdfStandardFont(PdfFontFamily.helvetica, 10);
    final bodyBoldFont = PdfStandardFont(PdfFontFamily.helvetica, 10, style: PdfFontStyle.bold);
    final bodyItalicFont = PdfStandardFont(PdfFontFamily.helvetica, 9.5, style: PdfFontStyle.italic);
    final h1Font = PdfStandardFont(PdfFontFamily.helvetica, 16, style: PdfFontStyle.bold);
    final h2Font = PdfStandardFont(PdfFontFamily.helvetica, 13.5, style: PdfFontStyle.bold);
    final h3Font = PdfStandardFont(PdfFontFamily.helvetica, 11.5, style: PdfFontStyle.bold);
    final codeFont = PdfStandardFont(PdfFontFamily.courier, 9);

    final textBrush = PdfSolidBrush(PdfColor(45, 55, 72));
    final boldBrush = PdfSolidBrush(PdfColor(26, 32, 44));
    final headingBrush = PdfSolidBrush(PdfColor(26, 32, 44));
    final quoteBrush = PdfSolidBrush(PdfColor(74, 85, 104));
    final quoteBorderPen = PdfPen(PdfColor(26, 115, 232), width: 2.5);
    final rulePen = PdfPen(PdfColor(226, 232, 240), width: 0.6);

    int i = 0;
    while (i < lines.length) {
      final rawLine = lines[i];
      final line = rawLine.trim();

      if (line.isEmpty) {
        i++;
        continue;
      }

      // Check if we hit a Relevant Passages header (safety safeguard)
      if (RegExp(r'^#{2,4}\s*Relevant Passages', caseSensitive: false).hasMatch(line)) {
        break;
      }

      // 1. Horizontal Divider
      if (RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$').hasMatch(line)) {
        cursorY += 4;
        if (cursorY + 10 > clientSize.height) {
          currentPage = document.pages.add();
          clientSize = currentPage.getClientSize();
          cursorY = 10;
        }
        currentPage.graphics.drawLine(rulePen, Offset(0, cursorY), Offset(usableWidth, cursorY));
        cursorY += 8;
        i++;
        continue;
      }

      // 2. Markdown Table
      if (_isTableRow(lines[i]) && i + 1 < lines.length && _isTableDivider(lines[i + 1])) {
        final headerCells = _extractTableCells(lines[i]);
        final dataRows = <List<String>>[];
        i += 2; // skip header and divider

        while (i < lines.length && _isTableRow(lines[i])) {
          dataRows.add(_extractTableCells(lines[i]));
          i++;
        }

        final colCount = headerCells.length;
        if (colCount > 0) {
          final grid = PdfGrid();
          grid.columns.add(count: colCount);
          for (int c = 0; c < colCount; c++) {
            grid.columns[c].width = usableWidth / colCount;
          }

          grid.headers.add(1);
          final header = grid.headers[0];
          for (int c = 0; c < colCount; c++) {
            header.cells[c].value = headerCells[c];
          }
          header.style.backgroundBrush = PdfSolidBrush(PdfColor(247, 250, 252));
          header.style.textBrush = boldBrush;
          header.style.font = PdfStandardFont(PdfFontFamily.helvetica, 9.5, style: PdfFontStyle.bold);

          for (final row in dataRows) {
            final pdfRow = grid.rows.add();
            for (int c = 0; c < colCount; c++) {
              pdfRow.cells[c].value = c < row.length ? row[c] : '';
            }
            pdfRow.style.font = bodyFont;
            pdfRow.style.textBrush = textBrush;
          }

          grid.style.cellPadding = PdfPaddings(left: 7, right: 7, top: 5, bottom: 5);

          if (cursorY + 60 > clientSize.height) {
            currentPage = document.pages.add();
            clientSize = currentPage.getClientSize();
            cursorY = 10;
          }

          final res = grid.draw(
            page: currentPage,
            bounds: Rect.fromLTWH(0, cursorY, usableWidth, clientSize.height - cursorY),
            format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
          );
          currentPage = res!.page;
          clientSize = currentPage.getClientSize();
          cursorY = res.bounds.bottom + 12;
        }
        continue;
      }

      // 3. Fenced Code Block
      if (line.startsWith('```')) {
        final codeLines = <String>[];
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('```')) {
          codeLines.add(lines[i]);
          i++;
        }
        if (i < lines.length) i++; // skip closing ```
        final codeText = codeLines.join('\n');

        cursorY += 6;
        if (cursorY + 40 > clientSize.height) {
          currentPage = document.pages.add();
          clientSize = currentPage.getClientSize();
          cursorY = 10;
        }

        final padding = 8.0;
        final codeElement = PdfTextElement(
          text: codeText,
          font: codeFont,
          brush: textBrush,
          format: PdfStringFormat(lineSpacing: 2),
        );
        final res = codeElement.draw(
          page: currentPage,
          bounds: Rect.fromLTWH(padding, cursorY + padding, usableWidth - (padding * 2), clientSize.height - cursorY - (padding * 2)),
          format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
        );

        final boxRect = Rect.fromLTWH(0, cursorY, usableWidth, (res!.bounds.bottom - cursorY) + padding);
        currentPage.graphics.drawRectangle(
          pen: PdfPen(PdfColor(226, 232, 240), width: 0.6),
          brush: PdfSolidBrush(PdfColor(248, 249, 250)),
          bounds: boxRect,
        );
        codeElement.draw(
          page: currentPage,
          bounds: Rect.fromLTWH(padding, cursorY + padding, usableWidth - (padding * 2), clientSize.height - cursorY - (padding * 2)),
          format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
        );

        currentPage = res.page;
        clientSize = currentPage.getClientSize();
        cursorY = res.bounds.bottom + 14;
        continue;
      }

      // 4. Headings
      if (line.startsWith('### ')) {
        final headingText = line.substring(4).replaceAll('**', '').trim();
        cursorY += 8;
        if (cursorY + 24 > clientSize.height) {
          currentPage = document.pages.add();
          clientSize = currentPage.getClientSize();
          cursorY = 10;
        }
        final el = PdfTextElement(text: headingText, font: h3Font, brush: headingBrush);
        final res = el.draw(
          page: currentPage,
          bounds: Rect.fromLTWH(0, cursorY, usableWidth, clientSize.height - cursorY),
          format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
        );
        currentPage = res!.page;
        clientSize = currentPage.getClientSize();
        cursorY = res.bounds.bottom + 6;
        i++;
        continue;
      }

      if (line.startsWith('## ')) {
        final headingText = line.substring(3).replaceAll('**', '').trim();
        cursorY += 10;
        if (cursorY + 30 > clientSize.height) {
          currentPage = document.pages.add();
          clientSize = currentPage.getClientSize();
          cursorY = 10;
        }
        final el = PdfTextElement(text: headingText, font: h2Font, brush: headingBrush);
        final res = el.draw(
          page: currentPage,
          bounds: Rect.fromLTWH(0, cursorY, usableWidth, clientSize.height - cursorY),
          format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
        );
        currentPage = res!.page;
        clientSize = currentPage.getClientSize();
        currentPage.graphics.drawLine(rulePen, Offset(0, res.bounds.bottom + 2), Offset(usableWidth, res.bounds.bottom + 2));
        cursorY = res.bounds.bottom + 8;
        i++;
        continue;
      }

      if (line.startsWith('# ')) {
        final headingText = line.substring(2).replaceAll('**', '').trim();
        cursorY += 12;
        if (cursorY + 34 > clientSize.height) {
          currentPage = document.pages.add();
          clientSize = currentPage.getClientSize();
          cursorY = 10;
        }
        final el = PdfTextElement(text: headingText, font: h1Font, brush: headingBrush);
        final res = el.draw(
          page: currentPage,
          bounds: Rect.fromLTWH(0, cursorY, usableWidth, clientSize.height - cursorY),
          format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
        );
        currentPage = res!.page;
        clientSize = currentPage.getClientSize();
        cursorY = res.bounds.bottom + 10;
        i++;
        continue;
      }

      // 5. Blockquote
      if (line.startsWith('>')) {
        final quoteLines = <String>[];
        while (i < lines.length && lines[i].trim().startsWith('>')) {
          quoteLines.add(lines[i].trim().replaceFirst(RegExp(r'^>\s*'), ''));
          i++;
        }
        final quoteText = quoteLines.join('\n').replaceAll('**', '').trim();
        final quotePaddingLeft = 14.0;
        final quoteWidth = usableWidth - quotePaddingLeft;

        final element = PdfTextElement(
          text: quoteText,
          font: bodyItalicFont,
          brush: quoteBrush,
          format: PdfStringFormat(lineSpacing: 2),
        );

        if (cursorY + 25 > clientSize.height) {
          currentPage = document.pages.add();
          clientSize = currentPage.getClientSize();
          cursorY = 10;
        }

        final topY = cursorY;
        final res = element.draw(
          page: currentPage,
          bounds: Rect.fromLTWH(quotePaddingLeft, cursorY, quoteWidth, clientSize.height - cursorY),
          format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
        );

        currentPage.graphics.drawLine(
          quoteBorderPen,
          Offset(4, topY),
          Offset(4, res!.bounds.bottom),
        );

        currentPage = res.page;
        clientSize = currentPage.getClientSize();
        cursorY = res.bounds.bottom + 8;
        continue;
      }

      // 6. Bullet Lists & Numbered Lists
      final listMatch = RegExp(r'^\s*([-*•]|\d+[.)])\s+(.*)$').firstMatch(rawLine);
      if (listMatch != null) {
        final marker = listMatch.group(1)!;
        final itemContent = listMatch.group(2)!.trim();
        final bulletSymbol = (marker == '-' || marker == '*' || marker == '•') ? '•' : marker;

        if (cursorY + 18 > clientSize.height) {
          currentPage = document.pages.add();
          clientSize = currentPage.getClientSize();
          cursorY = 10;
        }

        final boldLeadIn = RegExp(r'^\*\*([^*]+)\*\*[:\s]*(.*)$').firstMatch(itemContent);
        if (boldLeadIn != null) {
          final boldTitle = boldLeadIn.group(1)!.trim();
          final restText = boldLeadIn.group(2)!.replaceAll('**', '').trim();

          final boldEl = PdfTextElement(
            text: '$bulletSymbol   $boldTitle:',
            font: bodyBoldFont,
            brush: boldBrush,
          );
          final resHeader = boldEl.draw(
            page: currentPage,
            bounds: Rect.fromLTWH(6, cursorY, usableWidth - 6, clientSize.height - cursorY),
            format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
          );
          currentPage = resHeader!.page;
          clientSize = currentPage.getClientSize();
          cursorY = resHeader.bounds.bottom + 2;

          if (restText.isNotEmpty) {
            final bodyEl = PdfTextElement(
              text: restText,
              font: bodyFont,
              brush: textBrush,
              format: PdfStringFormat(lineSpacing: 2.2),
            );
            final resBody = bodyEl.draw(
              page: currentPage,
              bounds: Rect.fromLTWH(18, cursorY, usableWidth - 18, clientSize.height - cursorY),
              format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
            );
            currentPage = resBody!.page;
            clientSize = currentPage.getClientSize();
            cursorY = resBody.bounds.bottom + 6;
          }
        } else {
          final cleanItemText = itemContent.replaceAll('**', '');
          final bodyEl = PdfTextElement(
            text: '$bulletSymbol   $cleanItemText',
            font: bodyFont,
            brush: textBrush,
            format: PdfStringFormat(lineSpacing: 2.2),
          );
          final res = bodyEl.draw(
            page: currentPage,
            bounds: Rect.fromLTWH(6, cursorY, usableWidth - 6, clientSize.height - cursorY),
            format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
          );
          currentPage = res!.page;
          clientSize = currentPage.getClientSize();
          cursorY = res.bounds.bottom + 6;
        }

        i++;
        continue;
      }

      // 7. Regular Paragraphs
      final paraLines = <String>[];
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          !lines[i].trim().startsWith('#') &&
          !lines[i].trim().startsWith('```') &&
          !lines[i].trim().startsWith('>') &&
          !_isTableRow(lines[i]) &&
          !RegExp(r'^\s*([-*•]|\d+[.)])\s+').hasMatch(lines[i])) {
        paraLines.add(lines[i]);
        i++;
      }

      final paraText = paraLines.join('\n').trim();
      if (paraText.isNotEmpty) {
        if (cursorY + 20 > clientSize.height) {
          currentPage = document.pages.add();
          clientSize = currentPage.getClientSize();
          cursorY = 10;
        }

        final boldLeadIn = RegExp(r'^\*\*([^*]+)\*\*[:\s]*(.*)$', dotAll: true).firstMatch(paraText);
        if (boldLeadIn != null) {
          final boldTitle = boldLeadIn.group(1)!.trim();
          final restText = boldLeadIn.group(2)!.replaceAll('**', '').trim();

          final titleEl = PdfTextElement(
            text: '$boldTitle:',
            font: bodyBoldFont,
            brush: boldBrush,
          );
          final resTitle = titleEl.draw(
            page: currentPage,
            bounds: Rect.fromLTWH(0, cursorY, usableWidth, clientSize.height - cursorY),
            format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
          );
          currentPage = resTitle!.page;
          clientSize = currentPage.getClientSize();
          cursorY = resTitle.bounds.bottom + 2;

          if (restText.isNotEmpty) {
            final bodyEl = PdfTextElement(
              text: restText,
              font: bodyFont,
              brush: textBrush,
              format: PdfStringFormat(lineSpacing: 2.5),
            );
            final resBody = bodyEl.draw(
              page: currentPage,
              bounds: Rect.fromLTWH(0, cursorY, usableWidth, clientSize.height - cursorY),
              format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
            );
            currentPage = resBody!.page;
            clientSize = currentPage.getClientSize();
            cursorY = resBody.bounds.bottom + 8;
          }
        } else {
          final cleanText = paraText.replaceAll('**', '');
          final element = PdfTextElement(
            text: cleanText,
            font: bodyFont,
            brush: textBrush,
            format: PdfStringFormat(lineSpacing: 2.5),
          );
          final res = element.draw(
            page: currentPage,
            bounds: Rect.fromLTWH(0, cursorY, usableWidth, clientSize.height - cursorY),
            format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
          );
          currentPage = res!.page;
          clientSize = currentPage.getClientSize();
          cursorY = res.bounds.bottom + 8;
        }
      }
    }
  }

  /// Exports a single Q&A pair as a professional PDF document.
  static Future<PdfDownloadResult> generateSingleAnswerPdf({
    required String question,
    required String answer,
    String? spaceName,
    DateTime? timestamp,
  }) async {
    final cleanQuestion = StudioService.stripInlineDocumentReferences(question).trim();
    final cleanAnswer = StudioService.formatChatAnswer(answer);

    final document = PdfDocument();
    document.pageSettings.margins.all = 36;
    final sName = (spaceName != null && spaceName.isNotEmpty) ? spaceName : 'General Space';
    final dateStr = (timestamp ?? DateTime.now()).toLocal().toString().split('.').first;

    _setupHeaderAndFooter(document, spaceName: sName, documentTitle: cleanQuestion);

    final page = document.pages.add();
    final clientSize = page.getClientSize();
    final usableWidth = clientSize.width;

    // Document Title Banner
    final titleFont = PdfStandardFont(PdfFontFamily.helvetica, 16, style: PdfFontStyle.bold);
    final titleBrush = PdfSolidBrush(PdfColor(26, 32, 44));
    page.graphics.drawString(
      'NotebookPRO Q&A Export',
      titleFont,
      brush: titleBrush,
      bounds: Rect.fromLTWH(0, 0, usableWidth, 24),
    );

    // Meta Info
    final metaFont = PdfStandardFont(PdfFontFamily.helvetica, 8.5, style: PdfFontStyle.regular);
    final metaBrush = PdfSolidBrush(PdfColor(113, 128, 150));
    page.graphics.drawString(
      'Space: $sName   |   Exported: $dateStr',
      metaFont,
      brush: metaBrush,
      bounds: Rect.fromLTWH(0, 26, usableWidth, 16),
    );

    // Divider
    page.graphics.drawLine(
      PdfPen(PdfColor(226, 232, 240), width: 0.8),
      const Offset(0, 44),
      Offset(usableWidth, 44),
    );

    // Question Card / Banner
    final qFont = PdfStandardFont(PdfFontFamily.helvetica, 11, style: PdfFontStyle.bold);
    final qBrush = PdfSolidBrush(PdfColor(26, 115, 232));
    final qElement = PdfTextElement(
      text: 'Question: $cleanQuestion',
      font: qFont,
      brush: qBrush,
      format: PdfStringFormat(lineSpacing: 2),
    );

    final qResult = qElement.draw(
      page: page,
      bounds: Rect.fromLTWH(0, 54, usableWidth, clientSize.height - 54),
      format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
    );

    final answerPage = qResult!.page;
    final answerStartY = qResult.bounds.bottom + 12;

    // Render Answer Body
    _renderMarkdownContent(
      document: document,
      initialPage: answerPage,
      markdownText: cleanAnswer,
      startY: answerStartY,
    );

    final bytes = Uint8List.fromList(document.saveSync());
    document.dispose();

    final safeTitle = safePdfFilename(
      cleanQuestion.length > 40 ? cleanQuestion.substring(0, 37) : cleanQuestion,
    );

    return PdfDownloadResult(bytes: bytes, filename: safeTitle);
  }

  /// Exports a combined set of chat Q&A items as a comprehensive PDF report.
  static Future<PdfDownloadResult> generateCombinedAnswersPdf({
    required String title,
    required List<Map<String, String>> items,
    String? spaceName,
    DateTime? timestamp,
  }) async {
    final document = PdfDocument();
    document.pageSettings.margins.all = 36;
    final sName = (spaceName != null && spaceName.isNotEmpty) ? spaceName : 'General Space';
    final dateStr = (timestamp ?? DateTime.now()).toLocal().toString().split('.').first;

    _setupHeaderAndFooter(document, spaceName: sName, documentTitle: title);

    var currentPage = document.pages.add();
    var clientSize = currentPage.getClientSize();
    var usableWidth = clientSize.width;

    // Main Cover Header
    final titleFont = PdfStandardFont(PdfFontFamily.helvetica, 18, style: PdfFontStyle.bold);
    final titleBrush = PdfSolidBrush(PdfColor(26, 32, 44));
    currentPage.graphics.drawString(
      title,
      titleFont,
      brush: titleBrush,
      bounds: Rect.fromLTWH(0, 0, usableWidth, 26),
    );

    final metaFont = PdfStandardFont(PdfFontFamily.helvetica, 8.5, style: PdfFontStyle.regular);
    final metaBrush = PdfSolidBrush(PdfColor(113, 128, 150));
    currentPage.graphics.drawString(
      'Space: $sName   |   Items: ${items.length}   |   Exported: $dateStr',
      metaFont,
      brush: metaBrush,
      bounds: Rect.fromLTWH(0, 28, usableWidth, 16),
    );

    currentPage.graphics.drawLine(
      PdfPen(PdfColor(226, 232, 240), width: 1.0),
      const Offset(0, 48),
      Offset(usableWidth, 48),
    );

    double cursorY = 58;

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final q = item['question'] ?? 'Question';
      final a = item['answer'] ?? '';

      if (cursorY + 45 > clientSize.height) {
        currentPage = document.pages.add();
        clientSize = currentPage.getClientSize();
        cursorY = 10;
      }

      // Question Title
      final qHeaderFont = PdfStandardFont(PdfFontFamily.helvetica, 11.5, style: PdfFontStyle.bold);
      final qHeaderBrush = PdfSolidBrush(PdfColor(26, 115, 232));
      final qElement = PdfTextElement(
        text: '${i + 1}. $q',
        font: qHeaderFont,
        brush: qHeaderBrush,
        format: PdfStringFormat(lineSpacing: 2),
      );

      final qRes = qElement.draw(
        page: currentPage,
        bounds: Rect.fromLTWH(0, cursorY, usableWidth, clientSize.height - cursorY),
        format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
      );

      currentPage = qRes!.page;
      cursorY = qRes.bounds.bottom + 8;

      // Render Answer
      _renderMarkdownContent(
        document: document,
        initialPage: currentPage,
        markdownText: a,
        startY: cursorY,
      );

      // Advance page for next item if more items exist
      if (i < items.length - 1) {
        currentPage = document.pages.add();
        clientSize = currentPage.getClientSize();
        cursorY = 10;
      }
    }

    final bytes = Uint8List.fromList(document.saveSync());
    document.dispose();

    final safeTitle = safePdfFilename(title);
    return PdfDownloadResult(bytes: bytes, filename: safeTitle);
  }

  /// Exports a single NotebookEntry as a PDF document.
  static Future<PdfDownloadResult> generateNotebookEntryPdf({
    required NotebookEntry entry,
    String? spaceName,
  }) async {
    final document = PdfDocument();
    document.pageSettings.margins.all = 36;
    final sName = (spaceName != null && spaceName.isNotEmpty) ? spaceName : entry.spaceId;
    final createdStr = entry.createdAt.toLocal().toString().split('.').first;

    _setupHeaderAndFooter(document, spaceName: sName, documentTitle: entry.title);

    final page = document.pages.add();
    final clientSize = page.getClientSize();
    final usableWidth = clientSize.width;

    // Entry Title
    final titleFont = PdfStandardFont(PdfFontFamily.helvetica, 17, style: PdfFontStyle.bold);
    final titleBrush = PdfSolidBrush(PdfColor(26, 32, 44));
    page.graphics.drawString(
      entry.title,
      titleFont,
      brush: titleBrush,
      bounds: Rect.fromLTWH(0, 0, usableWidth, 26),
    );

    // Meta: tags and dates
    final tagsStr = entry.tags.isNotEmpty ? 'Tags: ${entry.tags.join(', ')}  •  ' : '';
    final metaFont = PdfStandardFont(PdfFontFamily.helvetica, 8.5);
    final metaBrush = PdfSolidBrush(PdfColor(113, 128, 150));
    page.graphics.drawString(
      '${tagsStr}Space: $sName  •  Updated: $createdStr',
      metaFont,
      brush: metaBrush,
      bounds: Rect.fromLTWH(0, 28, usableWidth, 16),
    );

    page.graphics.drawLine(
      PdfPen(PdfColor(226, 232, 240), width: 0.8),
      const Offset(0, 46),
      Offset(usableWidth, 46),
    );

    final rawText = quillOrPlainToText(entry.content);
    final cleanText = _normalizeEntryBodyForExport(entry, rawText);

    _renderMarkdownContent(
      document: document,
      initialPage: page,
      markdownText: cleanText,
      startY: 56,
    );

    final bytes = Uint8List.fromList(document.saveSync());
    document.dispose();

    final safeTitle = safePdfFilename(entry.title.isNotEmpty ? entry.title : 'notebook_entry');
    return PdfDownloadResult(bytes: bytes, filename: safeTitle);
  }

  /// Exports selected Notebook entries as a combined notebook PDF.
  static Future<PdfDownloadResult> generateSelectedNotebookEntriesPdf({
    required List<NotebookEntry> entries,
    String? spaceName,
    String title = 'Notebook Selection',
  }) async {
    final document = PdfDocument();
    document.pageSettings.margins.all = 36;
    final sName = (spaceName != null && spaceName.isNotEmpty) ? spaceName : 'General Space';

    _setupHeaderAndFooter(document, spaceName: sName, documentTitle: title);

    var currentPage = document.pages.add();
    var clientSize = currentPage.getClientSize();
    var usableWidth = clientSize.width;

    // Report Title
    final titleFont = PdfStandardFont(PdfFontFamily.helvetica, 18, style: PdfFontStyle.bold);
    currentPage.graphics.drawString(
      title,
      titleFont,
      brush: PdfSolidBrush(PdfColor(26, 32, 44)),
      bounds: Rect.fromLTWH(0, 0, usableWidth, 26),
    );

    final metaFont = PdfStandardFont(PdfFontFamily.helvetica, 8.5);
    currentPage.graphics.drawString(
      'Space: $sName   |   Total Entries: ${entries.length}',
      metaFont,
      brush: PdfSolidBrush(PdfColor(113, 128, 150)),
      bounds: Rect.fromLTWH(0, 28, usableWidth, 16),
    );

    currentPage.graphics.drawLine(
      PdfPen(PdfColor(226, 232, 240), width: 1.0),
      const Offset(0, 48),
      Offset(usableWidth, 48),
    );

    double cursorY = 58;

    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (cursorY + 40 > clientSize.height) {
        currentPage = document.pages.add();
        clientSize = currentPage.getClientSize();
        cursorY = 10;
      }

      // Entry Title Header
      final hFont = PdfStandardFont(PdfFontFamily.helvetica, 13, style: PdfFontStyle.bold);
      currentPage.graphics.drawString(
        '${i + 1}. ${entry.title}',
        hFont,
        brush: PdfSolidBrush(PdfColor(26, 115, 232)),
        bounds: Rect.fromLTWH(0, cursorY, usableWidth, 20),
      );
      cursorY += 22;

      final rawText = quillOrPlainToText(entry.content);
      final bodyText = _normalizeEntryBodyForExport(entry, rawText);
      _renderMarkdownContent(
        document: document,
        initialPage: currentPage,
        markdownText: bodyText,
        startY: cursorY,
      );

      if (i < entries.length - 1) {
        currentPage = document.pages.add();
        clientSize = currentPage.getClientSize();
        cursorY = 10;
      }
    }

    final bytes = Uint8List.fromList(document.saveSync());
    document.dispose();

    final safeTitle = safePdfFilename(title);
    return PdfDownloadResult(bytes: bytes, filename: safeTitle);
  }

  /// Saves the PDF bytes to device storage.
  /// Uses FilePicker on Android/Desktop with fallback to device directory.
  static Future<bool> savePdfFile({
    required String fileName,
    required Uint8List bytes,
    String dialogTitle = 'Save PDF Document',
  }) async {
    try {
      if (kIsWeb) {
        return false;
      }

      if (Platform.isAndroid || Platform.isIOS) {
        final selectedPath = await FilePicker.saveFile(
          dialogTitle: dialogTitle,
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
          bytes: bytes,
        );

        if (selectedPath != null && selectedPath.isNotEmpty) {
          try {
            final f = File(selectedPath);
            if (!f.existsSync() || f.lengthSync() == 0) {
              await f.writeAsBytes(bytes, flush: true);
            }
          } catch (_) {}
          return true;
        }

        // Automatic fallback: save to App/Downloads directory if user cancelled picker
        final baseDir = await getExternalStorageDirectory() ??
            await getApplicationDocumentsDirectory();
        final fallbackFile = File('${baseDir.path}/$fileName');
        await fallbackFile.writeAsBytes(bytes, flush: true);
        return true;
      }

      // Windows / Desktop
      final savePath = await FilePicker.saveFile(
        dialogTitle: dialogTitle,
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        bytes: bytes,
      );

      if (savePath == null || savePath.isEmpty) {
        final appDir = await getApplicationDocumentsDirectory();
        final file = File('${appDir.path}/$fileName');
        await file.writeAsBytes(bytes, flush: true);
        return true;
      }

      final file = File(savePath);
      if (!file.existsSync() || file.lengthSync() == 0) {
        await file.writeAsBytes(bytes, flush: true);
      }
      return true;
    } catch (e) {
      debugPrint('Error saving PDF file: $e');
      // Emergency fallback
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final file = File('${appDir.path}/$fileName');
        await file.writeAsBytes(bytes, flush: true);
        return true;
      } catch (_) {
        return false;
      }
    }
  }
}
