import 'package:flutter_test/flutter_test.dart';
import 'package:notebook_pro_app/services/prompt_builder.dart';
import 'package:notebook_pro_app/utils/answer_sanitizer.dart';

void main() {
  group('PromptBuilder Tests', () {
    test('inferUseCase detects use cases accurately', () {
      expect(PromptBuilder.inferUseCase('Summarize chapter 3'), equals(AnswerUseCase.summary));
      expect(PromptBuilder.inferUseCase('Make study notes on Docker'), equals(AnswerUseCase.notes));
      expect(PromptBuilder.inferUseCase('Explain Jenkins in detail'), equals(AnswerUseCase.explanation));
      expect(PromptBuilder.inferUseCase('How does backpropagation work?'), equals(AnswerUseCase.explanation));
      expect(PromptBuilder.inferUseCase('Can Jenkins run on Kubernetes?'), equals(AnswerUseCase.qa));
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

    test('qualityChecklist dynamically activates only when evidence exists in context', () {
      final mathChunks = ['The loss is given by \\frac{a}{b} and equation L = y - y_hat.'];
      final checklistWithMath = PromptBuilder.qualityChecklist('evaluate formula', AnswerUseCase.qa, mathChunks);
      expect(checklistWithMath, contains('in LaTeX'));

      final nonMathChunks = ['Jenkins automates integration and deployment.'];
      final checklistWithoutMath = PromptBuilder.qualityChecklist('evaluate formula', AnswerUseCase.qa, nonMathChunks);
      expect(checklistWithoutMath, isNot(contains('in LaTeX')));
    });

    test('buildSystemPrompt has no hardcoded entity names and includes syntax placeholders', () {
      final prompt = PromptBuilder.buildSystemPrompt(AnswerUseCase.explanation);
      expect(prompt, isNot(contains('Jenkins')));
      expect(prompt, isNot(contains('Docker')));
      expect(prompt, isNot(contains('Takeaway')));
      expect(prompt, contains('<Subject> is <category> that <purpose>'));
      expect(prompt, contains('- **<Term>**: <what it does or means>'));
    });

    test('prepareChunks strictly caps raw chunks to at most 6 chunks', () {
      final rawChunks = List.generate(8, (i) => '[${i + 1}] Book Title:\nEvidence line for chunk ${i + 1}.');
      final prepared = PromptBuilder.prepareChunks(rawChunks, 'Explain Jenkins in detail');
      expect(prepared.length, equals(6));
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
  });
}

