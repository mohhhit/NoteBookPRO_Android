import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:llamadart/llamadart.dart';

import '../models/app_models.dart';

class LocalLlmService {
  static LlamaEngine? _engine;
  static bool _isInitialized = false;

  static Future<void> initialize() async {
    if (_isInitialized) return;

    final docDir = await getApplicationDocumentsDirectory();
    final modelPath = '${docDir.path}/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf';
    final modelFile = File(modelPath);

    if (!await modelFile.exists()) {
      throw Exception(
        'Model not found at $modelPath.\n'
        'Please download Gemma 4 E4B GGUF and place it in the app documents directory.',
      );
    }

    final backend = LlamaBackend();
    _engine = LlamaEngine(backend);
    
    await _engine!.loadModel(
      modelPath,
      modelParams: const ModelParams(
        contextSize: 4096, // Increased to 4096 for RAG
        cacheTypeK: KvCacheType.q8_0,
        cacheTypeV: KvCacheType.q8_0,
      ),
    );

    _isInitialized = true;
  }

  static Future<String> generateQueryExpansion(String query) async {
    if (!_isInitialized || _engine == null) return query;
    
    final prompt = '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\nYou are an academic search assistant. Your ONLY job is to output 8 technical keywords, synonyms, or related terms for the user\'s query, separated by spaces. Do not write anything else. Do not use markdown.<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n$query<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n';
    
    String result = "";
    int tokens = 0;
    try {
      await for (final chunk in _engine!.generate(prompt, params: const GenerationParams(temp: 0.1, maxTokens: 20))) {
        result += chunk;
        tokens++;
        if (tokens > 20) break;
      }
    } catch (e) {
      print('Expansion error: $e');
    }
    return result.trim().replaceAll(RegExp(r'[^\w\s]'), ' ');
  }

  static Stream<String> generateResponse(List<ChatMessage> history, {List<String>? contextChunks}) async* {
    if (!_isInitialized || _engine == null) {
      throw Exception('LLM not initialized');
    }

    String systemText = '''You are the expert generation engine for NotebookPRO. Write a faithful, concise answer. Shorter is fine if the excerpts are limited.

STRICT GROUNDING: You MUST ONLY use information present inside the provided context. Do NOT use outside knowledge and do NOT hallucinate.

REQUIRED OUTPUT STRUCTURE:
- Use clear markdown headings with ### for major sections.
- Use bulleted breakdowns with bold key terms.
- Keep explanations dense and structured.

**Citation Rules:**
- Every factual sentence must be supported by a citation **[1]**.
- Citations must be inline and numeric only: **[n]** or **[n, m]**.
- Paraphrase facts and cite them. Do NOT make up information.

CORRECT CITATION FORMAT: "Kubernetes uses a declarative model [1]."
INCORRECT CITATION FORMAT: "According to Source [1], Kubernetes uses a declarative model."''';

    final buffer = StringBuffer();
    buffer.writeln('<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n$systemText<|eot_id|>');

    int lastUserIndex = history.lastIndexWhere((msg) => msg.role == 'user');

    for (int i = 0; i < history.length; i++) {
      var msg = history[i];
      if (msg.role == 'assistant' && msg.content.isEmpty) continue;
      
      String text = msg.content;
      
      if (i == lastUserIndex && contextChunks != null && contextChunks.isNotEmpty) {
        text = '''**===== START OF CONTEXT =====**

${contextChunks.join('\n\n')}

**===== END OF CONTEXT =====**

**Student's Question:** $text

**Instructions:** Answer ONLY using the context between the markers above. If the context does not contain the answer, say you do not have that information. Cite sources in brackets.''';
      }

      buffer.writeln('<|start_header_id|>${msg.role}<|end_header_id|>\n\n$text<|eot_id|>');
    }
    
    // Start assistant response
    buffer.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
    
    final fullPrompt = buffer.toString();
    print('\n================ EXACT LLM PROMPT DUMP FOR EXPERT TEST ================');
    for (var i = 0; i < fullPrompt.length; i += 800) {
      int end = (i + 800 < fullPrompt.length) ? i + 800 : fullPrompt.length;
      print(fullPrompt.substring(i, end));
    }
    print('=========================================================================\n');

    print('LLM: Starting generation with context size ${history.length} messages (Direct String Gen)');
    final startTime = DateTime.now();
    int tokenCount = 0;
    
    await for (final textChunk in _engine!.generate(
      buffer.toString(),
      params: const GenerationParams(temp: 0.1),
    )) {
      if (tokenCount == 0) {
        print('LLM: First token generated in ${DateTime.now().difference(startTime).inMilliseconds}ms');
      }
      
      if (textChunk.isNotEmpty) {
        tokenCount++;
        yield textChunk;
      }
    }
    
    print('LLM: Finished generation. Total tokens yielded: $tokenCount');
  }

  static void dispose() {
    _engine?.dispose();
    _engine = null;
    _isInitialized = false;
  }
}

