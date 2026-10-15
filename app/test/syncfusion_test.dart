import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

void main() {
  test('Syncfusion PDF creates and extracts text', () {
    final document = PdfDocument();
    final page = document.pages.add();
    page.graphics.drawString(
      'Data Warehouse and Data Lake Architecture with Calibri',
      PdfStandardFont(PdfFontFamily.helvetica, 12),
    );
    final bytes = document.saveSync();
    document.dispose();

    final loadedDoc = PdfDocument(inputBytes: bytes);
    final extracted = PdfTextExtractor(loadedDoc).extractText();
    loadedDoc.dispose();

    expect(extracted, contains('Data Warehouse and Data Lake Architecture'));
  });
}

