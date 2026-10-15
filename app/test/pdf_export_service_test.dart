import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  test('Syncfusion PDF creates multi-page paginated document with headers and footers', () {
    final document = PdfDocument();
    document.pageSettings.margins.all = 36;
    final pageSize = document.pageSettings.size;

    // Header template
    final header = PdfPageTemplateElement(Rect.fromLTWH(0, 0, pageSize.width, 30));
    header.graphics.drawString(
      'NoteBookPRO Export',
      PdfStandardFont(PdfFontFamily.helvetica, 8, style: PdfFontStyle.bold),
      brush: PdfSolidBrush(PdfColor(113, 128, 150)),
      bounds: Rect.fromLTWH(36, 10, pageSize.width - 72, 20),
    );
    header.graphics.drawLine(
      PdfPen(PdfColor(226, 232, 240), width: 0.5),
      const Offset(36, 25),
      Offset(pageSize.width - 36, 25),
    );
    document.template.top = header;

    // Footer template
    final footer = PdfPageTemplateElement(Rect.fromLTWH(0, 0, pageSize.width, 30));
    footer.graphics.drawLine(
      PdfPen(PdfColor(226, 232, 240), width: 0.5),
      const Offset(36, 5),
      Offset(pageSize.width - 36, 5),
    );
    footer.graphics.drawString(
      'Exported from NoteBookPRO',
      PdfStandardFont(PdfFontFamily.helvetica, 8, style: PdfFontStyle.italic),
      brush: PdfSolidBrush(PdfColor(113, 128, 150)),
      bounds: Rect.fromLTWH(36, 10, pageSize.width - 72, 20),
    );
    document.template.bottom = footer;

    final page = document.pages.add();
    final clientSize = page.getClientSize();

    // Draw Title
    final titleFont = PdfStandardFont(PdfFontFamily.helvetica, 18, style: PdfFontStyle.bold);
    final titleBrush = PdfSolidBrush(PdfColor(26, 32, 44));
    page.graphics.drawString(
      'Lakehouse Architecture Guide',
      titleFont,
      brush: titleBrush,
      bounds: Rect.fromLTWH(0, 0, clientSize.width, 30),
    );

    // Draw Question Banner
    final qFont = PdfStandardFont(PdfFontFamily.helvetica, 12, style: PdfFontStyle.bold);
    final qBrush = PdfSolidBrush(PdfColor(26, 115, 232));
    page.graphics.drawString(
      'Q: What is Delta Lake and how does it implement ACID?',
      qFont,
      brush: qBrush,
      bounds: Rect.fromLTWH(0, 40, clientSize.width, 24),
    );

    // Long body that creates multiple pages
    final answerText = List.generate(
      60,
      (i) => 'Item $i: Delta Lake brings reliability to data lakes by adding ACID transactions and scalable metadata handling.',
    ).join('\n\n');

    final bodyFont = PdfStandardFont(PdfFontFamily.helvetica, 10);
    final bodyBrush = PdfSolidBrush(PdfColor(45, 55, 72));
    final format = PdfStringFormat(lineSpacing: 2);
    final element = PdfTextElement(text: answerText, font: bodyFont, brush: bodyBrush, format: format);

    element.draw(
      page: page,
      bounds: Rect.fromLTWH(0, 70, clientSize.width, clientSize.height - 70),
      format: PdfLayoutFormat(layoutType: PdfLayoutType.paginate),
    );

    expect(document.pages.count, greaterThan(1));

    final Uint8List bytes = Uint8List.fromList(document.saveSync());
    document.dispose();

    expect(bytes.length, greaterThan(1500));

    final loadedDoc = PdfDocument(inputBytes: bytes);
    final extracted = PdfTextExtractor(loadedDoc).extractText();
    loadedDoc.dispose();

    expect(extracted, contains('Lakehouse Architecture Guide'));
    expect(extracted, contains('What is Delta Lake'));
    expect(extracted, contains('NoteBookPRO Export'));
  });
}

