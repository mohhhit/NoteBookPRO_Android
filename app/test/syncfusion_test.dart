import 'dart:ui';
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

  test('Syncfusion PdfGrid works', () {
    final document = PdfDocument();
    final page = document.pages.add();
    final grid = PdfGrid();
    grid.columns.add(count: 2);
    grid.headers.add(1);
    final header = grid.headers[0];
    header.cells[0].value = 'Col 1';
    header.cells[1].value = 'Col 2';
    final row = grid.rows.add();
    row.cells[0].value = 'Val 1';
    row.cells[1].value = 'Val 2';
    grid.draw(page: page, bounds: const Rect.fromLTWH(0, 0, 200, 100));
    final bytes = document.saveSync();
    document.dispose();
    expect(bytes.length, greaterThan(100));
  });

  test('Syncfusion styled PdfGrid with headers and borders', () {
    final document = PdfDocument();
    final page = document.pages.add();
    final grid = PdfGrid();
    grid.columns.add(count: 3);
    grid.headers.add(1);
    final header = grid.headers[0];
    header.cells[0].value = 'Feature';
    header.cells[1].value = 'Data Lake';
    header.cells[2].value = 'Data Warehouse';
    header.style.backgroundBrush = PdfSolidBrush(PdfColor(247, 250, 252));
    header.style.textBrush = PdfSolidBrush(PdfColor(26, 32, 44));
    header.style.font = PdfStandardFont(PdfFontFamily.helvetica, 9.5, style: PdfFontStyle.bold);

    final row = grid.rows.add();
    row.cells[0].value = 'Schema';
    row.cells[1].value = 'Schema-on-read';
    row.cells[2].value = 'Schema-on-write';
    row.style.font = PdfStandardFont(PdfFontFamily.helvetica, 9);

    grid.style.cellPadding = PdfPaddings(left: 6, right: 6, top: 5, bottom: 5);
    grid.draw(page: page, bounds: const Rect.fromLTWH(0, 0, 400, 200));
    final bytes = document.saveSync();
    document.dispose();
    expect(bytes.length, greaterThan(200));

    final loadedDoc = PdfDocument(inputBytes: bytes);
    final text = PdfTextExtractor(loadedDoc).extractText();
    loadedDoc.dispose();
    expect(text, contains('Feature'));
    expect(text, contains('Schema-on-read'));
    expect(text, contains('Schema-on-write'));
  });
}

