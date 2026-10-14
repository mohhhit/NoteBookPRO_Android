import 'package:notebook_pro_app/utils/answer_sanitizer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:notebook_pro_app/utils/response_sanitizer.dart';
import 'package:notebook_pro_app/providers/app_state.dart';
import 'package:notebook_pro_app/services/vector_db_service.dart';

void main() {
  group('ResponseSanitizer - Math Delimiters (Bug Fix 1)', () {
    test('converts bracket and parenthesis math delimiters', () {
      const input = r'Block: \[ x^2 + y^2 = z^2 \] and inline: \( a + b = c \)';
      final output = ResponseSanitizer.normalizeMathDelimiters(input);
      expect(output, contains(r'$$x^2 + y^2 = z^2$$'));
      expect(output, contains(r'$a + b = c$'));
    });

    test('preserves whitespace preceding and following inline math without collapsing', () {
      const input = r'and $ x = 5 $ is the value';
      final output = ResponseSanitizer.normalizeMathDelimiters(input);
      expect(output, equals(r'and $x = 5$ is the value'));
    });
  });

  group('ResponseSanitizer - Acronym Spacing & Formula Normalization (Bug Fix 3)', () {
    test('only spaces known metric acronyms and protects terms like gRPC, kNN, macOS, iOS', () {
      const input = 'We evaluate asMAE using gRPC on macOS and iOS with kNN classifier.';
      final output = ResponseSanitizer.normalizeFormulaEquations(input);
      expect(output, contains('as MAE'));
      expect(output, contains('gRPC'));
      expect(output, contains('macOS'));
      expect(output, contains('iOS'));
      expect(output, contains('kNN'));
    });

    test('wraps plain-text metric formulas with delimiters', () {
      const input = 'The formula: BLEU = exp(sum) where n is 4.';
      final output = ResponseSanitizer.normalizeFormulaEquations(input);
      expect(output, contains(r'$BLEU = exp(sum)$'));
    });
  });

  group('ResponseSanitizer - Bullet Indentation (Bug Fix 2)', () {
    test('preserves nested bullet indentation', () {
      const input = '* Top level\n  * Nested level 1\n    * Nested level 2';
      final output = ResponseSanitizer.sanitizeResponse(input);
      final lines = output.split('\n');
      expect(lines[0], equals('* Top level'));
      expect(lines[1], equals('  * Nested level 1'));
      expect(lines[2], equals('    * Nested level 2'));
    });
  });

  group('ResponseSanitizer - Markdown Table Repair', () {
    test('inserts missing separator row between header and body', () {
      const input = '| Feature | Value |\n| Name | Test |';
      final output = ResponseSanitizer.repairMarkdownTables(input);
      expect(output, contains('| --- | --- |'));
    });
  });

  group('ResponseSanitizer - Truncation Trimming', () {
    test('trims unfinished dangling conjunction at end of text', () {
      const input = 'This is complete. But the next thought was and';
      final output = ResponseSanitizer.trimToLastCompleteUnit(input);
      expect(output, equals('This is complete.'));
    });

    test('keeps already complete text intact', () {
      const input = 'Docker provides container isolation using namespaces and cgroups.';
      final output = ResponseSanitizer.trimToLastCompleteUnit(input);
      expect(output, equals(input));
    });
  });

  group('AppState - Citation Enforcer Exemptions', () {
    test('preserves markdown tables and display math without sentence deletion', () {
      const input = '''
### Evaluation Results
| Metric | Score |
| --- | --- |
| BLEU | 0.85 |

Here is the objective:
\$\$ L = \\sum (y - \\hat{y})^2 \$\$
''';

      final output = AppState.enforceCitationsAndCleanOutput(
        input,
        rawChunks: ['Unrelated text that has no overlap with the table.'],
      );

      expect(output, contains('| Metric | Score |'));
      expect(output, contains('| BLEU | 0.85 |'));
      expect(output, contains(r'$$ L = \sum (y - \hat{y})^2 $$'));
    });

    test('strips [n] and prevents [n] [1] artifact leakage', () {
      const input = 'Jenkins automates machine learning workflows [n] [1].';
      final output = AppState.enforceCitationsAndCleanOutput(
        input,
        rawChunks: ['Jenkins automates machine learning workflows, testing, and deployment pipelines.'],
      );

      expect(output, isNot(contains('[n]')));
      expect(output, contains('[1].'));
    });
  });

  group('ResponseSanitizer - Placeholder Stripping', () {
    test('strips unexpanded citation placeholders [n] and [placeholder]', () {
      const input = 'This statement has a placeholder [n] and another [placeholder].';
      final output = ResponseSanitizer.sanitizeResponse(input);
      expect(output, isNot(contains('[n]')));
      expect(output, isNot(contains('[placeholder]')));
    });
  });

  group('AppState - Term and Clause Deduplication', () {
    test('drops bullets that repeat an already defined bold term', () {
      const input = '''
### Key Points
- **containerd**: A high-level runtime that manages lifecycle events [1].
- **runc**: A low-level runtime that interfaces with kernel constructs such as namespaces and cgroups [1].
- **runc**: Operates as a low-level runtime executing lifecycle events by interfacing with the kernel [1].
''';
      const chunk = 'containerd is a high-level runtime that manages lifecycle events. runc is a low-level runtime that interfaces with kernel constructs such as namespaces and cgroups to execute lifecycle events.';

      final output = AppState.enforceCitationsAndCleanOutput(
        input,
        rawChunks: [chunk],
      );

      final lines = output.split('\n').where((l) => l.trim().startsWith('-')).toList();
      expect(lines.length, equals(2));
      expect(lines[0], contains('**containerd**'));
      expect(lines[1], contains('**runc**'));
      expect(output.indexOf('**runc**'), equals(output.lastIndexOf('**runc**')),
          reason: '**runc** should only appear once');
    });

    test('drops redundant bullets that pad or borrow clauses from existing bullets', () {
      const input = '''
### Key Points
- **containerd**: A high-level runtime that manages lifecycle events such as starting, stopping, and deleting containers [1].
- **Workflow & Lifecycle**: The process involves the Docker Engine, containerd, and runc working together to manage lifecycle events such as starting, stopping, and deleting containers [1].
''';
      const chunk = 'containerd is a high-level runtime that manages lifecycle events such as starting, stopping, and deleting containers. Docker Engine, containerd, and runc work together.';

      final output = AppState.enforceCitationsAndCleanOutput(
        input,
        rawChunks: [chunk],
      );

      final lines = output.split('\n').where((l) => l.trim().startsWith('-')).toList();
      expect(lines.length, equals(1),
          reason: 'The padded redundant bullet should be dropped');
      expect(lines[0], contains('**containerd**'));
      expect(output, isNot(contains('**Workflow & Lifecycle**')));
    });

    test('strips bold labels and stems word variations (automation vs automates) to drop redundant bullets', () {
      const input = '''
### Definition
Jenkins is an open-source server for automating machine learning pipelines [1].

### Key Points
- **Workflow Automation**: Jenkins automates machine learning pipelines and deployments [1].
- **ML CI/CD Management**: Jenkins automates machine learning pipelines [1].
- **ML Workflow Orchestration**: Jenkins automates machine learning workflows [1].
- **Jenkinsfile**: Defines the pipeline as code, triggering checkout, build, and test steps on every commit [2].
''';
      const chunk1 = 'Jenkins is an open-source automation server for automating machine learning pipelines and deployments.';
      const chunk2 = 'Jenkinsfile defines the pipeline as code, triggering checkout, build, and test steps on every commit.';

      final output = AppState.enforceCitationsAndCleanOutput(
        input,
        rawChunks: [chunk1, chunk2],
      );

      final lines = output.split('\n').where((l) => l.trim().startsWith('-')).toList();
      // Bullets 1, 2, and 3 simply repeat the pipeline automation fact (and the definition).
      // Only the Jenkinsfile bullet is a distinct, concrete mechanism.
      expect(lines.length, equals(1),
          reason: 'Repeated automation/management bullets must be dropped despite different bold labels');
      expect(lines[0], contains('**Jenkinsfile**'));
      expect(output, isNot(contains('**Workflow Automation**')));
      expect(output, isNot(contains('**ML CI/CD Management**')));
      expect(output, isNot(contains('**ML Workflow Orchestration**')));
    });

    test('cleans intra-sentence circular repetition within definitions', () {
      const input = '''
### Definition
Jenkins is an open-source automation platform for managing ML CI/CD workflows for managing ML CI/CD workflows [1].

### Key Points
- **Jenkinsfile**: Defines the pipeline as code, triggering checkout, build, and test steps on every commit [2].
''';
      const chunk1 = 'Jenkins is an open-source automation platform for managing ML CI/CD workflows.';
      const chunk2 = 'Jenkinsfile defines the pipeline as code, triggering checkout, build, and test steps on every commit.';

      final output = AppState.enforceCitationsAndCleanOutput(
        input,
        rawChunks: [chunk1, chunk2],
      );

      // The repeated circular phrase should be cleaned out of the definition sentence
      expect(output, contains('### Definition'));
      expect(output, contains('Jenkins is an open-source automation platform for managing ML CI/CD workflows [1].'));
      expect(output, isNot(contains('for managing ML CI/CD workflows for managing ML CI/CD workflows')));
    });
  });

  group('VectorDbService - Retrieval Noise Filters', () {
    test('isIndexLikeChunk detects catalog and index pages with high number density', () {
      const indexChunk = '''
82 Jenkins build system, 76 ML artifacts in, 45 model registry, 89 pipeline stages, 102 continuous delivery, 114 artifact store.
''';
      const proseChunk = '''
Jenkins is an open-source automation server that enables developers to build, test, and deploy applications automatically. It supports distributed builds and integration with version control systems.
''';

      expect(VectorDbService.isIndexLikeChunk(indexChunk), isTrue);
      expect(VectorDbService.isIndexLikeChunk(proseChunk), isFalse);
    });

    test('isPersonOrCitationFalsePositive detects author citations and drops non-technology matches', () {
      const authorChunk = '''
Box and G. M. Jenkins (1970) developed the autoregressive integrated moving average (ARIMA) methodology, widely considered the foundation for modern timeseries forecasting models.
''';
      const softwareChunk = '''
Jenkins is an automation server that executes pipelines triggered by source code commits.
''';

      expect(VectorDbService.isPersonOrCitationFalsePositive(authorChunk, 'jenkins'), isTrue);
      expect(VectorDbService.isPersonOrCitationFalsePositive(authorChunk, 'Jenkins'), isTrue);
      expect(VectorDbService.isPersonOrCitationFalsePositive(softwareChunk, 'jenkins'), isFalse);
    });
  });

  group('AppState - extractCoreEntity', () {
    test('extracts single core technical entity ignoring framing words', () {
      expect(AppState.extractCoreEntity('Explain Jenkins in detail'), equals('Jenkins'));
      expect(AppState.extractCoreEntity('What is Docker and how does it work?'), equals('Docker'));
    });

    test('extracts capitalized entity from complex multi-word workflow question', () {
      final entity = AppState.extractCoreEntity(
        'What is the complete lifecycle or workflow of Docker help containerization?',
      );
      expect(entity, equals('Docker'));
    });

    test('extracts capitalized technical acronyms', () {
      expect(AppState.extractCoreEntity('Explain DPDP act in detail'), equals('DPDP'));
    });

    test('extracts multi-word conceptual entity when lowercase', () {
      expect(AppState.extractCoreEntity('what is machine learning'), equals('machine learning'));
    });
  });

  group('AppState - Comparison Architecture & Artifact Cleaners', () {
    test('extractComparisonEntities extracts dual subjects cleanly', () {
      final res1 = AppState.extractComparisonEntities('Difference between Data Warehouse and Data Lake');
      expect(res1, isNotNull);
      expect(res1!['entityA'], equals('Data Warehouse'));
      expect(res1['entityB'], equals('Data Lake'));

      final res2 = AppState.extractComparisonEntities('Data Lake vs Data Warehouse');
      expect(res2, isNotNull);
      expect(res2!['entityA'], equals('Data Lake'));
      expect(res2['entityB'], equals('Data Warehouse'));

      final res3 = AppState.extractComparisonEntities('Compare Kafka and RabbitMQ');
      expect(res3, isNotNull);
      expect(res3!['entityA'], equals('Kafka'));
      expect(res3['entityB'], equals('RabbitMQ'));

      final res4 = AppState.extractComparisonEntities('Explain Docker in detail');
      expect(res4, isNull);
    });

    test('buildFacetsForComparison generates balanced dual-entity facets', () {
      final facets = AppState.buildFacetsForComparison('Data Warehouse', 'Data Lake');
      expect(facets.length, equals(6));
      expect(facets[5]['label'], contains('Cost, Scaling'));
      expect(facets[0]['anchor'], equals('Data Warehouse'));
      expect(facets[1]['anchor'], equals('Data Lake'));
      expect(facets[4]['label'], contains('Comparison'));
    });

    test('formatCleanBookTitle decodes HTML entities and strips ISBNs and repo hashes', () {
      const raw = 'Designing_Data-Intensive_Applications_O& 039 Reilly_9781449373320.pdf';
      final clean = AppState.formatCleanBookTitle(raw);
      expect(clean, equals('Designing Data-Intensive Applications'));

      const rawWithEntity = 'High_Performance_Spark_O&#039;Reilly_9781491927281.pdf';
      final cleanWithEntity = AppState.formatCleanBookTitle(rawWithEntity);
      expect(cleanWithEntity, equals('High Performance Spark'));
    });

    test('buildFacetsForTopic generates comprehensive architectural facets for Data Lake', () {
      final facets = AppState.buildFacetsForTopic('Explain Data Lake in detail');
      expect(facets.length, equals(6));
      expect(facets[0]['label'], contains('Raw Data'));
      expect(facets[0]['bm25Query'], contains('unstructured'));
      expect(facets[1]['label'], contains('Infrastructure'));
      expect(facets[1]['bm25Query'], contains('Hadoop'));
      expect(facets[2]['label'], contains('Formats'));
      expect(facets[2]['bm25Query'], contains('Parquet'));
      expect(facets[3]['label'], contains('Interoperability'));
      expect(facets[3]['bm25Query'], contains('Spark'));
      expect(facets[4]['label'], contains('Limitations'));
      expect(facets[4]['bm25Query'], contains('transactional'));
      expect(facets[5]['label'], contains('Lakehouses'));
      expect(facets[5]['bm25Query'], contains('ACID'));
    });

    test('enforceCitationsAndCleanOutput preserves multi-section architectural headings and bullets', () {
      const chunk1 = 'A data lake stores raw data across clusters of commodity hardware or cloud object storage.';
      const chunk2 = 'Historically data lakes used Hadoop and HDFS, while modern lakes use cloud object storage like S3.';
      const chunk3 = 'Data lakes support open columnar formats like Parquet and ORC alongside CSV and JSON.';
      const chunk4 = 'Processing engines like Spark and Presto execute queries directly on data lake storage.';
      const chunk5 = 'Original data lakes lacked native support for transactional updates and deletes.';
      const chunk6 = 'Data lakehouses introduce ACID transactions and governance on top of object storage.';

      const input = '''
### Definition and Core Architecture of the Data Lake
A data lake is originally conceived as a massive store where data is retained in raw, unprocessed form [1].
* **Foundational Infrastructure:** Historically, data lakes were built primarily on Hadoop and HDFS [2].
* **Data Formats:** Data lakes store data in open columnar standards like Parquet and ORC [3].

### Operational Characteristics and Interoperability
* **Storage and Portability:** Processing engines like Spark and Presto query data directly [4].

### Limitations and the Evolution to Lakehouses
* **Lack of Transactional Controls:** Original data lakes lacked support for updates or deletes [5].
* **The Lakehouse Convergence:** Modern data lakehouses add ACID transactions on object storage [6].
''';

      final output = AppState.enforceCitationsAndCleanOutput(
        input,
        rawChunks: [chunk1, chunk2, chunk3, chunk4, chunk5, chunk6],
      );

      // Verify all 3 thematic sections are preserved
      expect(output, contains('### Definition and Core Architecture of the Data Lake'));
      expect(output, contains('### Operational Characteristics and Interoperability'));
      expect(output, contains('### Limitations and the Evolution to Lakehouses'));

      // Verify bullets are cited with accurate backing chunks
      expect(output, contains('**Foundational Infrastructure:** Historically, data lakes were built primarily on Hadoop and HDFS [2].'));
      expect(output, contains('**Data Formats:** Data lakes store data in open columnar standards like Parquet and ORC [3].'));
      expect(output, contains('**Storage and Portability:** Processing engines like Spark and Presto query data directly [4].'));
      expect(output, contains('**Lack of Transactional Controls:** Original data lakes lacked support for updates or deletes [5].'));
      expect(output, contains('**The Lakehouse Convergence:** Modern data lakehouses add ACID transactions on object storage [6].'));
    });

    test('AnswerSanitizer.correctSchemaOverstatements corrects overstatement that schema guarantees data correctness', () {
      const input = 'Schema enforcement guarantees data correctness and ensures that data is always correct.';
      final cleaned = AnswerSanitizer.correctSchemaOverstatements(input);
      expect(cleaned, isNot(contains('guarantees data correctness')));
      expect(cleaned, contains('enforces structural schema constraints'));
      expect(cleaned, contains('ensures data conforms to defined schema constraints'));
    });

    test('enforceCitationsAndCleanOutput drops ungrounded bullets and supports dual citations for comparison claims', () {
      const chunk1 = 'A data warehouse is an analytical database using schema-on-write.';
      const chunk2 = 'A data lake stores raw files and objects in commodity storage.';

      const input = '''
### Definition
A data warehouse is designed for structured queries [1], whereas a data lake stores raw data [2].

### Key Points
- **Schema & Storage**: A data warehouse enforces schema-on-write, whereas a data lake stores raw files [1].
- **Quantum Acceleration**: Warehouses utilize neural hyperdimensional qubit registers for subatomic retrieval [1].
''';

      final output = AppState.enforceCitationsAndCleanOutput(
        input,
        rawChunks: [chunk1, chunk2],
      );

      // Multi-chunk grounded comparison bullet should have dual citation [1, 2]
      expect(output, contains('**Schema & Storage**: A data warehouse enforces schema-on-write, whereas a data lake stores raw files [1, 2].'));

      // Ungrounded hallucination (quantum acceleration) MUST be dropped from Key Points
      expect(output, isNot(contains('Quantum Acceleration')));
      expect(output, isNot(contains('qubit registers')));
    });

    test('enforceCitationsAndCleanOutput rejects empty bullets and protects lead-in colons', () {
      const chunk1 = 'A data warehouse is an analytical repository using schema-on-write.';
      const chunk2 = 'A data lake stores raw files and objects for machine learning.';

      const input = '''
### Definition
A data warehouse is designed for structured queries [1], whereas a data lake stores raw data [2].

### Key Points
Key differences between the data lake and a data warehouse include:
* **Data Lake:** [1].
* **Data Warehouse:** [1].
* **Schema Strategy**: A data warehouse enforces schema-on-write, whereas a data lake stores raw files [1].
''';

      final output = AppState.enforceCitationsAndCleanOutput(
        input,
        rawChunks: [chunk1, chunk2],
      );

      // Empty bullets MUST be dropped
      expect(output, isNot(contains('* **Data Lake:** [1].')));
      expect(output, isNot(contains('* **Data Warehouse:** [1].')));

      // Lead-in clause ending with colon MUST NOT have a citation attached
      expect(output, isNot(contains('include: [1].')));
      expect(output, isNot(contains('include: [2].')));

      // Substantive bullet MUST be preserved
      expect(output, contains('**Schema Strategy**: A data warehouse enforces schema-on-write'));
    });
  });
}

