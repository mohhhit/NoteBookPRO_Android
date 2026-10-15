import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notebook_pro_app/main.dart';

void main() {
  group('parseMessagePassages parsing tests', () {
    test('cleanly separates main answer and passages with standard separator', () {
      const content = '''A data lakehouse is a modern architecture that combines elements of data lakes and warehouses.

---
### Relevant Passages
**[1] Delta Lake: The Definitive Guide** (2024) — *Architecture*:
> "A lakehouse combines the key benefits of data lakes and data warehouses."

**[2] Designing Data-Intensive Applications** (2017) — *Storage*:
> "Storage engines organize data on disk."''';

      final parsed = parseMessagePassages(content);
      expect(parsed.mainContent, equals('A data lakehouse is a modern architecture that combines elements of data lakes and warehouses.'));
      expect(parsed.passagesContent, isNotNull);
      expect(parsed.passagesContent, contains('**[1] Delta Lake: The Definitive Guide**'));
      expect(parsed.passagesContent, contains('**[2] Designing Data-Intensive Applications**'));
      expect(parsed.passageCount, equals(2));
    });

    test('handles Windows \\r\\n line endings and variations without separator line', () {
      const content = "Apache Airflow is a workflow orchestrator.\r\n\r\n### Relevant Passages\r\n**[1] Airflow in Action** (2021) — *DAGs*:\r\n> \"DAGs define the workflow graph.\"";
      final parsed = parseMessagePassages(content);
      expect(parsed.mainContent, equals('Apache Airflow is a workflow orchestrator.'));
      expect(parsed.passagesContent, contains('**[1] Airflow in Action**'));
      expect(parsed.passageCount, equals(1));
    });

    test('returns null passages when content has no passages section', () {
      const content = 'Hello! How can I assist your studies today?';
      final parsed = parseMessagePassages(content);
      expect(parsed.mainContent, equals('Hello! How can I assist your studies today?'));
      expect(parsed.passagesContent, isNull);
      expect(parsed.passageCount, equals(0));
    });

    test('preserves coverage note at the end of passages', () {
      const content = '''Here is what was found.

---
### Relevant Passages
**[1] Textbook A** — *Concept*:
> "Quote here."

*Note: No textbook coverage found in your library for: modern streaming.*''';

      final parsed = parseMessagePassages(content);
      expect(parsed.passagesContent, contains('*Note: No textbook coverage found in your library for: modern streaming.*'));
      expect(parsed.passageCount, equals(1));
    });
  });

  group('RelevantPassagesDropdown widget tests', () {
    testWidgets('starts collapsed by default and expands/collapses on tap', (tester) async {
      const passagesMarkdown = '''**[1] Delta Lake** (2024) — *Architecture*:
> "A lakehouse combines data lakes and data warehouses."

**[2] Streaming Systems** (2018) — *Pipelines*:
> "Pipelines process unbounded streams."''';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RelevantPassagesDropdown(
                passagesMarkdown: passagesMarkdown,
                count: 2,
              ),
            ),
          ),
        ),
      );

      // Verify header is rendered with title and badge
      expect(find.text('Relevant Passages'), findsOneWidget);
      expect(find.text('2 sources'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);

      // Body text should not be visible before tap
      expect(find.textContaining('A lakehouse combines data lakes'), findsNothing);

      // Tap on the header bar to expand
      await tester.tap(find.text('Relevant Passages'));
      await tester.pumpAndSettle();

      // Body text should now be visible
      expect(find.textContaining('A lakehouse combines data lakes'), findsOneWidget);
      expect(find.textContaining('Pipelines process unbounded streams'), findsOneWidget);

      // Tap again to collapse
      await tester.tap(find.text('Relevant Passages'));
      await tester.pumpAndSettle();

      // Body should be hidden again
      expect(find.textContaining('A lakehouse combines data lakes'), findsNothing);
    });
  });
}

