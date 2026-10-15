import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:notebook_pro_app/models/studio_models.dart';
import 'package:notebook_pro_app/services/local_database_service.dart';
import 'package:notebook_pro_app/services/studio_service.dart';
import 'package:notebook_pro_app/services/pdf_export_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('StudioService - Title Derivation & Answer Formatting Tests', () {
    test('deriveTitleFromQuestion extracts clean titles correctly', () {
      expect(
        StudioService.deriveTitleFromQuestion('What is a Lakehouse?'),
        equals('What is a Lakehouse?'),
      );

      // Strips markdown headers and bullets
      expect(
        StudioService.deriveTitleFromQuestion('### What is Lakehouse Architecture?'),
        equals('What is Lakehouse Architecture?'),
      );
      expect(
        StudioService.deriveTitleFromQuestion('* Explain Delta Lake transactions'),
        equals('Explain Delta Lake transactions'),
      );

      // Takes only the first line for multi-line prompts
      expect(
        StudioService.deriveTitleFromQuestion('First line of query\nSecond line with extra details'),
        equals('First line of query'),
      );

      // Truncates long questions to max 60 chars with ellipsis
      final longQuery = 'How does the Apache Iceberg metadata specification coordinate concurrent writes and snapshot isolation in cloud object stores?';
      final derived = StudioService.deriveTitleFromQuestion(longQuery);
      expect(derived.length, lessThanOrEqualTo(60));
      expect(derived.endsWith('...'), isTrue);

      // Empty string fallback
      expect(
        StudioService.deriveTitleFromQuestion('   '),
        equals('Notebook Entry'),
      );
    });

    test('formatChatAnswer strips raw relevant passages dump, cleans citations, and formats math and lists', () {
      final rawChatOutput = '''
A Data Lakehouse unites data lakes and data warehouses [1, 2].

### Key Capabilities
* **ACID Transactions**: Provides snapshot isolation for reliable writes [1].
* **Schema Enforcement**: Prevents corrupt data entry (Document 2).

The variance is given by \$\\sigma^2 = \\frac{1}{N} \\sum (x_i - \\mu)^2\$.

---
### Relevant Passages
[1] Delta Lake Guide: Delta Lake brings ACID transactions to Apache Spark and big data workloads.
[2] Fundamentals of Data Engineering: Data warehouses enforce schema-on-write while lakes store raw files.
''';

      final formatted = StudioService.formatChatAnswer(rawChatOutput);

      // 1. Must NOT contain the raw passages dump
      expect(formatted, isNot(contains('### Relevant Passages')));
      expect(formatted, isNot(contains('Delta Lake Guide: Delta Lake brings ACID')));
      expect(formatted, isNot(contains('Fundamentals of Data Engineering: Data warehouses')));

      // 2. Must NOT contain inline bracket or document citations
      expect(formatted, isNot(contains('[1, 2]')));
      expect(formatted, isNot(contains('[1]')));
      expect(formatted, isNot(contains('(Document 2)')));

      // 3. Must normalize math expressions
      expect(formatted, contains('σ^2'));
      expect(formatted, contains('∑'));
      expect(formatted, contains('μ'));

      // 4. Must preserve the core content and structure
      expect(formatted, contains('A Data Lakehouse unites data lakes and data warehouses.'));
      expect(formatted, contains('* **ACID Transactions**: Provides snapshot isolation for reliable writes.'));
      expect(formatted, contains('* **Schema Enforcement**: Prevents corrupt data entry.'));
    });
  });

  group('StudioService & LocalDatabaseService - SQLite Notebook CRUD Tests', () {
    late Database db;

    setUp(() async {
      db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      await LocalDatabaseService.createTables(db);
      LocalDatabaseService.setDatabase(db);

      // Insert a dummy space so foreign keys are satisfied
      await db.insert('spaces', {
        'id': 'test-space-1',
        'name': 'Test Research Space',
        'file_count': 2,
        'chat_count': 1,
        'created_at': DateTime.now().toIso8601String(),
      });
    });

    tearDown(() async {
      await db.close();
      LocalDatabaseService.setDatabase(null);
    });

    test('addChatToNotebook cleans raw chat response and saves formatted note', () async {
      final rawAnswerWithChunks = '''
A Data Lakehouse combines data lakes with ACID transactions [1].

* **Storage**: Parquet on object storage [1].
* **Transactions**: ACID guarantees via Delta transaction log [2].

---
### Relevant Passages
[1] Delta Lake Definitive Guide: Raw chunk text that should never be saved into notebook...
''';

      final entry = await StudioService.addChatToNotebook(
        spaceId: 'test-space-1',
        question: 'What is a Data Lakehouse?',
        answer: rawAnswerWithChunks,
        chatId: 'chat-101',
        assistantTimestamp: '2026-10-15T10:00:00Z',
        spaceName: 'Test Research Space',
      );

      expect(entry.id, isNotEmpty);
      expect(entry.spaceId, equals('test-space-1'));
      expect(entry.title, equals('What is a Data Lakehouse?'));
      expect(entry.sourceType, equals('chat'));
      expect(entry.sourceId, equals('chat-101'));
      expect(entry.tags, contains('chat'));
      expect(entry.tags, contains('saved_from_reply'));

      // Verify the content is clean and formatted
      expect(entry.content, contains('Q: What is a Data Lakehouse?'));
      expect(entry.content, contains('A: A Data Lakehouse combines data lakes with ACID transactions.'));
      expect(entry.content, isNot(contains('### Relevant Passages')));
      expect(entry.content, isNot(contains('Raw chunk text that should never be saved')));
      expect(entry.content, isNot(contains('[1]')));

      expect(entry.metadata!['chat_id'], equals('chat-101'));
      expect(entry.metadata!['space_name'], equals('Test Research Space'));

      // Retrieve via listNotebookEntries
      final entries = await StudioService.listNotebookEntries(spaceId: 'test-space-1');
      expect(entries.length, equals(1));
      expect(entries.first.id, equals(entry.id));
      expect(entries.first.title, equals('What is a Data Lakehouse?'));
    });

    test('createNotebookEntry, updateNotebookEntry, and deleteNotebookEntry perform full lifecycle', () async {
      // 1. Create manual note
      final created = await StudioService.createNotebookEntry(
        spaceId: 'test-space-1',
        title: 'Meeting Notes - RAG Engine',
        content: '## Action Items\n* Integrate Syncfusion PDF\n* Support on-device SQLite notes',
        sourceType: 'manual',
        tags: ['meeting', 'rag'],
      );

      expect(created.id, isNotEmpty);
      expect(created.title, equals('Meeting Notes - RAG Engine'));
      expect(created.sourceType, equals('manual'));
      expect(created.tags, contains('meeting'));

      // 2. Fetch single entry
      final fetched = await StudioService.getNotebookEntry(created.id);
      expect(fetched.id, equals(created.id));
      expect(fetched.content, contains('## Action Items'));

      // 3. Update entry
      final updated = await StudioService.updateNotebookEntry(
        entryId: created.id,
        title: 'Updated Meeting Notes',
        content: '## Action Items\n* Done integrating Syncfusion PDF',
        tags: ['meeting', 'completed'],
      );

      expect(updated.title, equals('Updated Meeting Notes'));
      expect(updated.content, contains('Done integrating Syncfusion PDF'));
      expect(updated.tags, contains('completed'));

      // Verify persistence after update
      final reloaded = await StudioService.getNotebookEntry(created.id);
      expect(reloaded.title, equals('Updated Meeting Notes'));

      // 4. Delete entry
      await StudioService.deleteNotebookEntry(created.id);
      final remaining = await StudioService.listNotebookEntries(spaceId: 'test-space-1');
      expect(remaining.isEmpty, isTrue);
    });

    test('listNotebookEntries sorts entries by updated_at DESC and filters by spaceId', () async {
      // Insert another space
      await db.insert('spaces', {
        'id': 'test-space-2',
        'name': 'Other Space',
        'file_count': 0,
        'chat_count': 0,
        'created_at': DateTime.now().toIso8601String(),
      });

      await StudioService.createNotebookEntry(
        spaceId: 'test-space-1',
        title: 'Older Note',
        content: 'Content 1',
      );
      await Future.delayed(const Duration(milliseconds: 10));
      await StudioService.createNotebookEntry(
        spaceId: 'test-space-1',
        title: 'Newer Note',
        content: 'Content 2',
      );
      await StudioService.createNotebookEntry(
        spaceId: 'test-space-2',
        title: 'Space 2 Note',
        content: 'Content in space 2',
      );

      final space1Entries = await StudioService.listNotebookEntries(spaceId: 'test-space-1');
      expect(space1Entries.length, equals(2));
      expect(space1Entries[0].title, equals('Newer Note'));
      expect(space1Entries[1].title, equals('Older Note'));

      final space2Entries = await StudioService.listNotebookEntries(spaceId: 'test-space-2');
      expect(space2Entries.length, equals(1));
      expect(space2Entries[0].title, equals('Space 2 Note'));

      final allEntries = await StudioService.listNotebookEntries();
      expect(allEntries.length, equals(3));
    });
  });

  group('StudioService & PdfExportService - PDF Generation Tests', () {
    test('exportSingleAnswerPdf formats markdown tables, code blocks, bold bullets, and cleans citations', () async {
      final richAnswerWithChunks = '''
### Architectural Comparison

| Dimension | Data Lake | Data Warehouse |
| --- | --- | --- |
| Data Structure | Raw and unstructured | Structured and typed |
| Schema Design | Schema-on-read | Schema-on-write |
| Processing | Spark, Presto | SQL Query Engine |

```python
# Delta Lake Table Definition
delta_table = DeltaTable.forPath(spark, "/data/lakehouse")
```

* **ACID Transactions**: Supported via the _delta_log transaction log [1].
* **Time Travel**: Allows querying historical version snapshots [2].

> Note: Modern lakehouses eliminate the dual-system copy overhead.

---
### Relevant Passages
[1] Delta Lake Guide: Transaction log records commits sequentially...
[2] Cloud Data Warehouses: Modern data systems require transaction coordination...
''';

      final result = await StudioService.exportSingleAnswerPdf(
        spaceId: 'Data Architecture',
        question: 'Explain Delta Lake ACID transactions',
        answer: richAnswerWithChunks,
      );

      expect(result.filename, equals('Explain_Delta_Lake_ACID_transactions.pdf'));
      expect(result.filename, endsWith('.pdf'));
      expect(result.bytes, isNotEmpty);

      // Verify valid PDF magic bytes '%PDF'
      final header = String.fromCharCodes(result.bytes.sublist(0, 4));
      expect(header, equals('%PDF'));

      // Load document and verify content was rendered
      final doc = PdfDocument(inputBytes: result.bytes);
      expect(doc.pages.count, greaterThanOrEqualTo(1));

      final extractedText = PdfTextExtractor(doc).extractText();
      doc.dispose();

      // Check Header & Question Card
      expect(extractedText, contains('Data Architecture'));
      expect(extractedText, contains('Explain Delta Lake ACID transactions'));

      // Check Table Cells Rendered via PdfGrid
      expect(extractedText, contains('Dimension'));
      expect(extractedText, contains('Data Structure'));
      expect(extractedText, contains('Schema Design'));
      expect(extractedText, contains('Schema-on-read'));
      expect(extractedText, contains('Schema-on-write'));

      // Check Code Block Rendered
      expect(extractedText, contains('DeltaTable.forPath'));

      // Check Bold Bullet Headers Rendered
      expect(extractedText, contains('ACID Transactions:'));
      expect(extractedText, contains('Time Travel:'));
      expect(extractedText, contains('eliminate the dual-system copy overhead'));

      // Check that raw passages dump and citations are NOT in the PDF
      expect(extractedText, isNot(contains('Relevant Passages')));
      expect(extractedText, isNot(contains('Transaction log records commits sequentially')));
      expect(extractedText, isNot(contains('[1]')));
    });

    test('exportCombinedAnswersPdf generates full chat export with multiple formatted Q&A sections', () async {
      final items = [
        {
          'question': 'What is a Data Lake?',
          'answer': 'A storage repository that holds raw data in its native format until needed [1].\n\n---\n### Relevant Passages\n[1] Book: Chunk...',
        },
        {
          'question': 'What is a Data Warehouse?',
          'answer': 'A structured repository optimized for reporting and analysis with schema-on-write [2].',
        },
        {
          'question': 'How do they compare?',
          'answer': 'Lakehouses unite both architectures by running analytical engines directly on object storage.',
        },
      ];

      final result = await StudioService.exportCombinedAnswersPdf(
        spaceId: 'Big Data Research',
        chatTitle: 'Lakehouse Comparison Chat',
        items: items,
      );

      expect(result.filename, equals('Lakehouse_Comparison_Chat.pdf'));
      expect(result.filename, endsWith('.pdf'));
      expect(result.bytes.length, greaterThan(2000));

      final doc = PdfDocument(inputBytes: result.bytes);
      expect(doc.pages.count, greaterThanOrEqualTo(1));

      final extractedText = PdfTextExtractor(doc).extractText();
      doc.dispose();

      expect(extractedText, contains('Lakehouse Comparison Chat'));
      expect(extractedText, contains('1. What is a Data Lake?'));
      expect(extractedText, contains('2. What is a Data Warehouse?'));
      expect(extractedText, contains('3. How do they compare?'));
      expect(extractedText, contains('native format'));
      expect(extractedText, contains('schema-on-write'));
      expect(extractedText, isNot(contains('Relevant Passages')));
      expect(extractedText, isNot(contains('[1]')));
    });

    test('exportNotebookEntryPdf & exportSelectedNotebookEntriesPdf normalize chat entries to avoid duplicate questions', () async {
      final entry1 = NotebookEntry(
        id: 'entry-1',
        spaceId: 'space-a',
        title: 'Lakehouse Design Patterns',
        content: 'Q: Lakehouse Design Patterns\n\nA: # Lakehouse Design\n\n* **Medallion Architecture**: Bronze, Silver, Gold layers.\n* **Engine Caching**: Cache hot data in fast memory.',
        sourceType: 'chat',
        tags: ['architecture', 'lakehouse'],
        createdAt: DateTime(2026, 10, 15, 10, 0),
        updatedAt: DateTime(2026, 10, 15, 11, 0),
      );

      final entry2 = NotebookEntry(
        id: 'entry-2',
        spaceId: 'space-a',
        title: 'ACID Guarantees',
        content: '## Isolation Levels\nDelta Lake supports Snapshot Isolation and Serializable isolation.',
        sourceType: 'manual',
        tags: ['database'],
        createdAt: DateTime(2026, 10, 15, 12, 0),
        updatedAt: DateTime(2026, 10, 15, 12, 30),
      );

      // Single entry export
      final singleResult = await PdfExportService.generateNotebookEntryPdf(
        entry: entry1,
        spaceName: 'Space Alpha',
      );
      expect(singleResult.bytes, isNotEmpty);
      final doc1 = PdfDocument(inputBytes: singleResult.bytes);
      final text1 = PdfTextExtractor(doc1).extractText();
      doc1.dispose();

      expect(text1, contains('Lakehouse Design Patterns'));
      expect(text1, contains('Medallion Architecture:'));
      // Verifies question is not duplicated inside the body
      expect(text1, isNot(contains('Q: Lakehouse Design Patterns')));

      // Selected entries export
      final multiResult = await PdfExportService.generateSelectedNotebookEntriesPdf(
        entries: [entry1, entry2],
        spaceName: 'Space Alpha',
        title: 'Selected Research Notes',
      );
      expect(multiResult.bytes, isNotEmpty);
      final doc2 = PdfDocument(inputBytes: multiResult.bytes);
      final text2 = PdfTextExtractor(doc2).extractText();
      doc2.dispose();

      expect(text2, contains('Selected Research Notes'));
      expect(text2, contains('Lakehouse Design Patterns'));
      expect(text2, contains('ACID Guarantees'));
      expect(text2, contains('Snapshot Isolation'));
      expect(text2, isNot(contains('Q: Lakehouse Design Patterns')));
    });
  });
}
