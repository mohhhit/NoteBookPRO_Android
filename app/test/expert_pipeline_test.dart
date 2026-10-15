import 'package:flutter_test/flutter_test.dart';
import 'package:notebook_pro_app/services/prompt_builder.dart';
import 'package:notebook_pro_app/services/document_processor.dart';
import 'package:notebook_pro_app/utils/answer_sanitizer.dart';
import 'package:notebook_pro_app/providers/app_state.dart';
import 'package:notebook_pro_app/services/reranker_service.dart';

void main() {
  group('PromptBuilder Tests', () {
    test('inferUseCase detects use cases accurately', () {
      expect(PromptBuilder.inferUseCase('Summarize chapter 3'), equals(AnswerUseCase.summary));
      expect(PromptBuilder.inferUseCase('Make study notes on Docker'), equals(AnswerUseCase.notes));
      expect(PromptBuilder.inferUseCase('Explain Jenkins in detail'), equals(AnswerUseCase.explanation));
      expect(PromptBuilder.inferUseCase('How does backpropagation work?'), equals(AnswerUseCase.explanation));
      expect(PromptBuilder.inferUseCase('Can Jenkins run on Kubernetes?'), equals(AnswerUseCase.qa));
      expect(PromptBuilder.inferUseCase('Difference between Data Warehouse and Data Lake in terms of data storage'), equals(AnswerUseCase.comparison));
      expect(PromptBuilder.inferUseCase('Compare Postgres vs MongoDB regarding indexing'), equals(AnswerUseCase.comparison));
      expect(PromptBuilder.inferUseCase('Contrast monolith vs microservices'), equals(AnswerUseCase.comparison));
    });

    test('cleanChunkHeader strips z-library and unknown year tags', () {
      const chunk = '[0000] [1] Machine_Learning (z-library.org).pdf (General):\nHere is the body text.';
      final cleaned = PromptBuilder.cleanChunkHeader(chunk);
      expect(cleaned, isNot(contains('z-library')));
      expect(cleaned, isNot(contains('[0000]')));
      expect(cleaned, isNot(contains('.pdf')));
      expect(cleaned, contains('[1] Machine_Learning (General):\nHere is the body text.'));
    });

    test('compressChunk leaves short chunks <= 650 chars uncut', () {
      const header = '[1] Clean Code:';
      final shortBody = 'A' * 300;
      final chunk = '$header\n$shortBody';
      final compressed = PromptBuilder.compressChunk(chunk, 'Clean code principles');
      expect(compressed, equals(chunk));
    });

    test('compressChunk preserves list items following continuation phrase like "used to:"', () {
      const header = '[1] Jenkins Automation:';
      const body = '''
In modern software engineering, Jenkins is an open-source automation server.
Jenkins can be used to:
- Automatically initiate the training process when new data becomes available.
- Execute test suites to evaluate model performance, accuracy, and generalization.
- Orchestrate the rollout of a model to staging or production after passing benchmarks.
This tool has been widely adopted by organizations for CI/CD pipelines.
''';
      final chunk = '$header\n$body';
      final compressed = PromptBuilder.compressChunk(chunk, 'Explain Jenkins in detail');
      expect(compressed, contains('Automatically initiate the training process'));
      expect(compressed, contains('Execute test suites'));
      expect(compressed, contains('Orchestrate the rollout'));
    });

    test('compressChunk preserves component descriptions and penalizes meta headings', () {
      const header = '[1] Airflow Architecture:';
      const body = '''
15.1 Revisiting the Airflow architecture in production.
Back in chapter 1, we showed the Airflow architecture displayed in figure 15.1.
At minimum, Airflow consists of a number of components:
- The API server serves as the main entrypoint and interface where users visualize workflows.
- The scheduler is responsible for scheduling tasks and polling the queue.
- The DAG processor parses DAG definitions from files into serialized representations.
- Workers execute the tasks dispatched from the scheduler queue.
- The metastore database holds all task instances, DAG runs, and operational state.
As shown in figure 15.2, these components communicate over network interfaces.
This long sentence fills extra characters to ensure that the body text exceeds the maximum character limit for testing chunk compression thoroughly and cleanly.
''';
      final chunk = '$header\n$body';
      final compressed = PromptBuilder.compressChunk(chunk, 'Explain Airflow architecture in detail', maxChars: 600);
      expect(compressed, contains('API server serves as the main entrypoint'));
      expect(compressed, contains('scheduler is responsible for scheduling'));
      expect(compressed, contains('DAG processor parses DAG definitions'));
      expect(compressed, contains('Workers execute the tasks'));
      expect(compressed, contains('metastore database holds all task instances'));
      expect(compressed, isNot(contains('This long sentence fills extra characters')));
    });

    test('qualityChecklist dynamically activates only when evidence exists in context', () {
      final mathChunks = ['The loss is given by \\frac{a}{b} and equation L = y - y_hat.'];
      final checklistWithMath = PromptBuilder.qualityChecklist('evaluate formula', AnswerUseCase.qa, mathChunks);
      expect(checklistWithMath, contains('in LaTeX'));

      final nonMathChunks = ['Jenkins automates integration and deployment.'];
      final checklistWithoutMath = PromptBuilder.qualityChecklist('evaluate formula', AnswerUseCase.qa, nonMathChunks);
      expect(checklistWithoutMath, isNot(contains('in LaTeX')));
    });

    test('buildSystemPrompt has no hardcoded entity names and uses dynamic evidence-driven structure', () {
      final prompt = PromptBuilder.buildSystemPrompt(AnswerUseCase.explanation);
      expect(prompt, isNot(contains('Jenkins')));
      expect(prompt, isNot(contains('Docker')));
      expect(prompt, isNot(contains('Takeaway')));
      expect(prompt, isNot(contains('Hadoop')));
      expect(prompt, isNot(contains('Parquet')));
      expect(prompt, isNot(contains('data lake')));
      expect(prompt, isNot(contains('### Foundational Infrastructure and Storage')));
      expect(prompt, isNot(contains('### Processing Engines and Interoperability')));
      expect(prompt, contains('- **<Key Concept>**:'));
      expect(prompt, contains('INDEPENDENT & OBJECTIVE DEFINITION'));
      expect(prompt, contains('PRECISE OPERATIONAL MECHANICS'));
      expect(prompt, contains('TEMPORAL & ARCHITECTURAL SCOPING'));
      expect(prompt, contains('BALANCED & NUANCED COMPARISONS'));
      expect(prompt, contains('DYNAMIC THEMATIC SECTIONS'));
      expect(prompt, contains('EVIDENCE-PROPORTIONAL DEPTH'));
      expect(prompt, contains('EVIDENCE SYNTHESIS'));
      expect(prompt, contains('DEPTH EXPECTATIONS'));
      expect(prompt, contains('ARCHITECTURAL ROLES & INTERACTIONS'));
      expect(prompt, contains('TECHNICAL PRECISION OVER METAPHORS'));
      expect(prompt, isNot(contains('"### Modern Evolution"')));
    });

    test('qualityChecklist dynamically adds schema rules only when context contains schema evidence', () {
      final schemaChunks = ['Data lakes use schema-on-read where structure is applied upon reading.'];
      final withSchema = PromptBuilder.qualityChecklist('Explain data storage', AnswerUseCase.explanation, schemaChunks);
      expect(withSchema, contains('schema-on-read'));

      final algoChunks = ['Gradient descent optimizes parameters via step size alpha.'];
      final withoutSchema = PromptBuilder.qualityChecklist('Explain gradient descent', AnswerUseCase.explanation, algoChunks);
      expect(withoutSchema, isNot(contains('schema-on-read')));
    });

    test('prepareChunks strictly caps raw chunks to at most 6 chunks', () {
      final rawChunks = List.generate(8, (i) => '[${i + 1}] Book Title:\nEvidence line for chunk ${i + 1}.');
      final prepared = PromptBuilder.prepareChunks(rawChunks, 'Explain Jenkins in detail');
      expect(prepared.length, equals(6));
    });

    test('formatChunksToXml wraps chunks in XML with index, source, facet, and section attributes', () {
      final chunks = [
        '[1] Fundamentals of Data Engineering (2022) (Foundational Infrastructure):\n[Section: Chapter 4 > Object Storage]\nData lakes decouple storage from compute.',
        '[2] Cloud Data Architectures (General):\nColumnar formats provide high compression.',
      ];
      final xml = PromptBuilder.formatChunksToXml(chunks);
      expect(xml, contains('<source_material>'));
      expect(xml, contains('</source_material>'));
      expect(xml, contains('<document index="1" source="Fundamentals of Data Engineering (2022)" facet="Foundational Infrastructure" section="Chapter 4 &gt; Object Storage">'));
      expect(xml, contains('<document index="2" source="Cloud Data Architectures">'));
      expect(xml, contains('Data lakes decouple storage from compute.'));
    });

    test('buildUserMessage formats context into XML <source_material> tags', () {
      final chunks = ['[1] Clean Code (General):\nFunctions should be small.'];
      final message = PromptBuilder.buildUserMessage('What are clean functions?', chunks, AnswerUseCase.qa);
      expect(message, contains('<source_material>'));
      expect(message, contains('<document index="1" source="Clean Code">'));
      expect(message, contains('Functions should be small.'));
      expect(message, contains('Instructions: Answer ONLY using facts from the <source_material> documents above.'));
    });

    test('extractScopePhrase extracts restrictive scope phrase or returns null', () {
      expect(PromptBuilder.extractScopePhrase('Difference between Data Warehouse and Data Lake in terms of data storage'), equals('data storage'));
      expect(PromptBuilder.extractScopePhrase('Compare React and Flutter regarding state management'), equals('state management'));
      expect(PromptBuilder.extractScopePhrase('Explain Docker in detail with respect to networking'), equals('networking'));
      expect(PromptBuilder.extractScopePhrase('Explain Jenkins in detail'), isNull);
    });

    test('buildSystemPrompt for comparison strictly mandates Overview and Key Differences with scope', () {
      final prompt = PromptBuilder.buildSystemPrompt(AnswerUseCase.comparison, scope: 'data storage');
      expect(prompt, contains('### Overview'));
      expect(prompt, contains('### Key Differences'));
      expect(prompt, contains('STRICT SCOPE CONFINEMENT'));
      expect(prompt, contains('data storage'));
      expect(prompt, contains('NO REPETITION'));
      expect(prompt, contains('DUAL-SIDED'));
    });
  });

  group('DocumentProcessor Structural Hierarchy Tests', () {
    test('chunkText detects chapter and section headings and injects breadcrumbs', () {
      final processor = DocumentProcessor();
      const text = '''
Chapter 4: Modern Data Architecture

4.2 Object Storage and Data Lakes

Data lakes decouple storage from compute, allowing independent scaling of resources.
Raw data is retained in native formats such as Parquet, ORC, and JSON.
Downstream query engines query this data directly without monolithic database engines.
''';

      final chunks = processor.chunkText(text);
      expect(chunks, isNotEmpty);
      expect(chunks.first, contains('[Section: Chapter 4: Modern Data Architecture > 4.2 Object Storage and Data Lakes]'));
      expect(DocumentProcessor.extractBreadcrumb(chunks.first), equals('Chapter 4: Modern Data Architecture > 4.2 Object Storage and Data Lakes'));
    });
  });

  group('AnswerSanitizer Tests', () {
    test('strips thinking tokens and academic notes', () {
      const raw = '''<think>Thinking process here</think>
### Definition
Jenkins is an automation server.
### Academic Note:
Internal dev comments here''';

      final clean = AnswerSanitizer.finalize(raw);
      expect(clean, isNot(contains('<think>')));
      expect(clean, isNot(contains('Thinking process here')));
      expect(clean, isNot(contains('### Academic Note:')));
      expect(clean, isNot(contains('Internal dev comments here')));
      expect(clean, contains('Jenkins is an automation server.'));
    });

    test('isMathOrTableLine protects display math, tables, and formula lines', () {
      expect(AnswerSanitizer.isMathOrTableLine(r'$$ L = \sum (y - \hat{y})^2 $$'), isTrue);
      expect(AnswerSanitizer.isMathOrTableLine('| Header 1 | Header 2 |'), isTrue);
      expect(AnswerSanitizer.isMathOrTableLine('| --- | --- |'), isTrue);
      expect(AnswerSanitizer.isMathOrTableLine(r'$x = \frac{a}{b}$'), isTrue);
      expect(AnswerSanitizer.isMathOrTableLine('Jenkins is an automation server.'), isFalse);
    });

    test('trimToCompleteUnit trims truncated endings cleanly', () {
      const truncated = 'Sentence one is complete. Sentence two was cut off and';
      final trimmed = AnswerSanitizer.trimToCompleteUnit(truncated);
      expect(trimmed, equals('Sentence one is complete.'));
    });

    test('correctTechnicalContradictions corrects schema-on-read write attribution', () {
      const raw = 'With schema-on-read, the schema is dynamically created when data is written [2].';
      final cleaned = AnswerSanitizer.correctTechnicalContradictions(raw);
      expect(cleaned, isNot(contains('created when data is written')));
      expect(cleaned, contains('structure is interpreted when data is read rather than enforced before storage'));
    });

    test('correctTechnicalContradictions qualifies direct transcoding claims without processing', () {
      const raw = 'Data in columnar storage can be directly transcoded between formats without processing [2].';
      final cleaned = AnswerSanitizer.correctTechnicalContradictions(raw);
      expect(cleaned, isNot(contains('directly transcoded between formats without processing')));
      expect(cleaned, contains('converted across formats using schema mapping and processing engines'));
    });

    test('correctTechnicalContradictions neutralizes definitions subordinating data lakes to lakehouses', () {
      const raw = 'A data lake is primarily designed as the storage foundation of a lakehouse [1].';
      final cleaned = AnswerSanitizer.correctTechnicalContradictions(raw);
      expect(cleaned, isNot(contains('storage foundation of a lakehouse')));
      expect(cleaned, contains('centralized repository for storing raw, structured, semistructured, and unstructured data at scale'));
    });

    test('correctTechnicalContradictions qualifies absolute schema-less statements', () {
      const raw = 'While data warehouses enforce validation, data lakes remain schema-less [1].';
      final cleaned = AnswerSanitizer.correctTechnicalContradictions(raw);
      expect(cleaned, isNot(contains('remain schema-less')));
      expect(cleaned, contains('schema-on-read'));
    });

    test('correctTechnicalContradictions scopes transaction and isolation limitations to traditional data lakes', () {
      const raw = 'Data lakes lack transactions and table mutations [5].';
      final cleaned = AnswerSanitizer.correctTechnicalContradictions(raw);
      expect(cleaned, contains('traditional data lakes lacked native support for ACID transactions'));
    });

    test('correctTechnicalContradictions nuances warehouse storage comparisons', () {
      const raw = 'Data warehouses only rely on locally vertically scaled storage [1].';
      final cleaned = AnswerSanitizer.correctTechnicalContradictions(raw);
      expect(cleaned, isNot(contains('only rely on locally vertically scaled storage')));
      expect(cleaned, contains('traditional warehouses utilized vertically coupled storage, whereas modern cloud warehouses and lakes decouple storage from compute'));
    });

    test('sanitizeInformalTropes replaces cynical tropes and vague scaling colloquialisms', () {
      const raw = 'A data lake is a glorified distributed filesystem where files grow unbounded over time.';
      final cleaned = AnswerSanitizer.sanitizeInformalTropes(raw);
      expect(cleaned, isNot(contains('glorified distributed filesystem')));
      expect(cleaned, isNot(contains('grow unbounded over time')));
      expect(cleaned, contains('distributed storage system'));
      expect(cleaned, contains('accommodate expanding data volumes across distributed storage'));
    });

    test('sanitizeInformalTropes replaces promotional metaphors with rigorous technical terms', () {
      const raw = 'Airflow acts as an orchestrator conductor to produce a harmonious result with operators specific to perform actions and A-to-B operations.';
      final cleaned = AnswerSanitizer.sanitizeInformalTropes(raw);
      expect(cleaned, isNot(contains('orchestrator conductor')));
      expect(cleaned, isNot(contains('harmonious result')));
      expect(cleaned, isNot(contains('A-to-B operations')));
      expect(cleaned, contains('workflow orchestrator'));
      expect(cleaned, contains('reliable pipeline execution'));
      expect(cleaned, contains('operators designed to execute discrete tasks and data transfers'));
    });

    test('correctSchemaOverstatements corrects infinitive verb error "to enforces"', () {
      const raw = 'The system functions to enforces structural schema constraints [1].';
      final cleaned = AnswerSanitizer.correctSchemaOverstatements(raw);
      expect(cleaned, contains('to enforce structural schema constraints'));
    });

    test('correctTechnicalContradictions handles plural agreement for schema-less claims', () {
      const raw = 'Data lakes remains schema-less [1].';
      final cleaned = AnswerSanitizer.correctTechnicalContradictions(raw);
      expect(cleaned, contains('Data lakes employ schema-on-read rather than rigid write-time enforcement'));
    });

    test('sanitizeInformalTropes neutralizes toxic/swamp author metaphors', () {
      const raw = 'Without governance, the data lake becomes a data swamp with polluted or toxic tables.';
      final cleaned = AnswerSanitizer.sanitizeInformalTropes(raw);
      expect(cleaned, isNot(contains('data swamp')));
      expect(cleaned, isNot(contains('polluted or toxic')));
      expect(cleaned, contains('uncataloged and poorly governed data stores'));
      expect(cleaned, contains('unmanaged and inconsistent due to lack of governance'));
    });
  });

  group('AppState Comparison, Verification & Passages Tests', () {
    test('checkAndCleanUngroundedCausation strips ungrounded causal clause when evidence is absent', () {
      final citedWordSets = [
        {'data', 'warehouse', 'producers', 'consumers', 'support'},
      ];
      const sentence = 'A data warehouse better facilitates multiple producers or consumers due to its rule enforcement [1].';
      final cleaned = AppState.checkAndCleanUngroundedCausation(sentence, citedWordSets);
      expect(cleaned, isNot(contains('due to its rule enforcement')));
      expect(cleaned, contains('A data warehouse better facilitates multiple producers or consumers [1].'));
    });

    test('checkAndCleanUngroundedCausation preserves causal clause when reason words match cited chunk', () {
      final citedWordSets = [
        {'data', 'warehouse', 'rule', 'enforcement', 'integrity', 'constraints'},
      ];
      const sentence = 'A data warehouse better facilitates multiple producers or consumers due to its rule enforcement [1].';
      final cleaned = AppState.checkAndCleanUngroundedCausation(sentence, citedWordSets);
      expect(cleaned, contains('due to its rule enforcement'));
    });

    test('formatCleanBookTitle thoroughly removes curly braces, libgen tags, years, and HTML entities', () {
      const raw = 'Delta Lake_ The Definitive Guide_ Modern Data Lakehouse Architectures with Data Lakes{Prashanth Babu...}(2024, O&_039_Reilly Media){107716181} libgen.li.pdf';
      final cleaned = AppState.formatCleanBookTitle(raw);
      expect(cleaned, equals('Delta Lake The Definitive Guide Modern Data Lakehouse Architectures with Data Lakes'));
      expect(cleaned, isNot(contains('{')));
      expect(cleaned, isNot(contains('libgen')));
      expect(cleaned, isNot(contains('O&_039_')));
      expect(cleaned, isNot(contains('2024')));
    });

    test('buildBestMatchingPassages extracts chunk sentence with highest lexical overlap rather than intro snippet', () {
      final allResults = [
        {
          'content': 'Chapter 1 introduces databases and tables. In 1970, relational algebra was established. Vertically scaled warehouses store relations in specialized block stores with high infrastructure costs.',
          'metadata': {
            'filename': 'Data_Systems.pdf',
            'publication_year': '2021',
          },
          'facet_label': 'Storage Architecture',
        },
      ];
      const response = '### Key Differences\n- **Cost and Scaling**: Warehouses store relations in specialized block stores with high infrastructure costs [1].';
      final passages = AppState.buildBestMatchingPassages(
        allResults: allResults,
        responseText: response,
        query: 'Difference between Data Warehouse and Data Lake in terms of data storage',
      );
      expect(passages, hasLength(1));
      expect(passages.first['index'], equals('1'));
      expect(passages.first['text'], contains('Vertically scaled warehouses store relations in specialized block stores with high infrastructure costs'));
      expect(passages.first['text'], isNot(startsWith('Chapter 1 introduces')));
    });

    test('enforceCitationsAndCleanOutput restricts headings to Overview and Key Differences for comparison use case', () {
      const input = '''
### Overview
Warehouses and lakes differ in data storage layout and cost models.

### Key Differences
- **Storage Layout**: Warehouses store structured tables, whereas lakes store objects [1].

### Transaction Management and Consistency
- **ACID Controls**: Warehouses provide transactions [1].
''';
      final rawChunks = [
        'Warehouses and lakes differ in data storage layout and cost models. Warehouses store structured tables, whereas lakes store objects. Warehouses provide transactions.'
      ];
      final output = AppState.enforceCitationsAndCleanOutput(
        input,
        rawChunks: rawChunks,
        useCase: AnswerUseCase.comparison,
      );
      expect(output, contains('### Overview'));
      expect(output, contains('### Key Differences'));
      expect(output, isNot(contains('### Transaction Management and Consistency')));
    });
  });

  group('Recall, Soft Gate, and Yes/No Reasoning Tests', () {
    test('isYesNoQuestion accurately classifies auxiliary verb questions', () {
      expect(PromptBuilder.isYesNoQuestion('Does a traditional data warehouse accommodate unstructured data?'), isTrue);
      expect(PromptBuilder.isYesNoQuestion('Can Jenkins run on Kubernetes?'), isTrue);
      expect(PromptBuilder.isYesNoQuestion('Is Delta Lake an open table format?'), isTrue);
      expect(PromptBuilder.isYesNoQuestion('Would columnar storage improve read throughput?'), isTrue);
      expect(PromptBuilder.isYesNoQuestion('Has Airflow 3.0 separated the DAG processor?'), isTrue);

      expect(PromptBuilder.isYesNoQuestion('Explain Apache Airflow in detail'), isFalse);
      expect(PromptBuilder.isYesNoQuestion('What is a data warehouse?'), isFalse);
      expect(PromptBuilder.isYesNoQuestion('Difference between data warehouse and data lake'), isFalse);
    });

    test('eraFacets produces domain-agnostic historical and modern facets', () {
      final facets = PromptBuilder.eraFacets('data warehouse');
      expect(facets.length, equals(2));
      expect(facets[0], contains('traditional legacy earlier approach'));
      expect(facets[1], contains('modern current recent approach'));
    });

    test('buildUserMessage generates XML-bounded sources, yes/no guidance, and nuanced partial coverage instruction', () {
      final chunks = [
        '[1] Delta Lake (Storage):\nDelta Lake provides ACID transactions and parquet columnar files on cloud object storage.'
      ];
      final message = PromptBuilder.buildUserMessage(
        'Does a traditional data warehouse accommodate images?',
        chunks,
        AnswerUseCase.qa,
      );

      // Verify XML bounding
      expect(message, contains('<source_material>'));
      expect(message, contains('<document index="1" source="Delta Lake" facet="Storage"'));
      expect(message, contains('</source_material>'));

      // Verify Yes/No guidance
      expect(message, contains('This is a yes/no question: begin with Yes, No or Partly, then give the evidence'));
      expect(message, contains('Statements such as "X lacks Y" or "X requires Y" answer it.'));

      // Verify Nuanced Refusal instruction
      expect(message, contains('If the context covers only part of the question, answer that part and say what is missing;'));
      expect(message, contains('say you do not have the information only when the context contains nothing relevant.'));
    });

    test('RerankResult encapsulates soft gate partial match flag', () {
      final result = RerankResult(
        rankedCandidates: [
          {'content': 'Traditional data warehouses support structured relational tables.', 'rerank_score': -2.3}
        ],
        isCovered: true,
        topScore: -2.3,
        isPartialMatch: true,
      );

      expect(result.isCovered, isTrue);
      expect(result.isPartialMatch, isTrue);
      expect(result.topScore, equals(-2.3));
    });

    test('extractCoreEntity handles long yes/no queries with accommodation verbs and typos', () {
      final entity = AppState.extractCoreEntity('Does a traditional data warehouse accomodate images?');
      expect(entity.toLowerCase(), contains('traditional data warehouse'));
      expect(entity.toLowerCase(), contains('images'));
      expect(entity.toLowerCase(), isNot(startsWith('does')));
      expect(entity.toLowerCase(), isNot(contains('accomodate')));
    });
  });
}


