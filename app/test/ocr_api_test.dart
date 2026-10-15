import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:notebook_pro_app/services/document_processor.dart';
import 'package:notebook_pro_app/services/vector_db_service.dart';

void main() {
  test('OCR APIs compile check', () {
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    expect(textRecognizer, isNotNull);
  });

  test('pdfx methods check', () {
    void checkTypes(pdfx.PdfDocument doc, pdfx.PdfPage page) async {
      final count = doc.pagesCount;
      final pageImg = await page.render(
        width: page.width * 2.0,
        height: page.height * 2.0,
        format: pdfx.PdfPageImageFormat.jpeg,
        backgroundColor: '#FFFFFF',
        quality: 85,
      );
      final bytes = pageImg?.bytes;
      expect(bytes, isNull);
    }
    expect(checkTypes, isNotNull);
  });

  test('DocumentProcessor chunks text properly with metadata prefix', () {
    final processor = DocumentProcessor();
    final sampleText = List.generate(20, (i) => 'This is sentence number $i explaining distributed storage architectures and fault tolerance.').join(' ');
    final chunks = processor.chunkText(
      sampleText,
      sourceFilename: 'Big Data Textbook.pdf',
      chunkSize: 700,
      overlap: 120,
    );
    expect(chunks.isNotEmpty, isTrue);
    expect(chunks.first, startsWith('Source Document: Big Data Textbook.pdf\n---\n'));
  });

  test('DocumentProcessor handles non-existent file cleanly', () async {
    final processor = DocumentProcessor();
    expect(
      () => processor.processFile('non_existent_path.pdf'),
      throwsA(isA<Exception>()),
    );
  });

  test('Check if standard Lakehouse chunk is false positive noise', () {
    const chunk = '''
Source Document: [2024] Delta Lake_ The Definitive Guide.pdf
---
[Section: Chapter 1 > Lakehouse]
A data lakehouse is a new, open data management architecture that combines the best elements of data lakes and data warehouses: the low cost, flexibility, and scalability of a data lake with the data management and ACID transactions of a data warehouse.
''';
    final isNoise = VectorDbService.isChunkTechnicalNoise(chunk);
    print('IS NOISE RESULT: $isNoise');
    expect(isNoise, isFalse);
  });
}

