import 'package:flutter_test/flutter_test.dart';
import 'package:notebook_pro_app/providers/app_state.dart';

void main() {
  test('Investigate verifier behavior on realistic full response', () {
    final chunk1 = '''
Jenkins is an open-source automation server that integrates with many development, testing, and deployment technologies.
In this context, it facilitates the automation of complex workflows, enabling integration, testing, deployment, and scaling of machine learning models.
''';

    final chunk2 = '''
Jenkins provides a reliable environment where pipeline triggers can execute workflows manually or automatically in response to repository changes or configured events, facilitating team collaboration.
''';

    final rawChunks = [chunk1, chunk2];

    final fullResponse = '''
### Definition
Jenkins is an open-source automation server commonly used to automate software builds, testing, and deployment through CI/CD pipelines. In the provided textbook materials, its application is discussed specifically in the context of machine-learning workflows [1].

### Key Details from Library
- Jenkins performs data integrity and quality checks.
- Jenkins can initiate the training process automatically when new data is available.
- Jenkins executes test suites to validate model accuracy, performance, and generalization.
- Jenkins orchestrates the rollout of a model to a staging or production environment after passing specified benchmarks.
- Jenkins facilitates the automation of complex workflows, enabling integration, testing, deployment, and scaling of machine learning models.

### Dimensions Not Covered in Library
The uploaded books do not cover Jenkins controller/agent architecture, Jenkinsfile syntax, or plugin management.
''';

    print('\n================ INPUT RESPONSE ================');
    print(fullResponse);

    final cleaned = AppState.enforceCitationsAndCleanOutput(
      fullResponse,
      rawChunks: rawChunks,
    );

    print('\n================ CLEANED RESPONSE ================');
    print(cleaned);
    print('==================================================\n');
  });
}

