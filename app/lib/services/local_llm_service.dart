import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:llamadart/llamadart.dart';

import '../models/app_models.dart';

class LocalLlmService {
  static LlamaEngine? _engine;
  static bool _isInitialized = false;
  static bool _isLlama = false;

  static Future<void> initialize() async {
    if (_isInitialized) return;

    final docDir = await getApplicationDocumentsDirectory();
    final modelPath = '${docDir.path}/Llama-3.2-3B-Instruct-Q4_K_M.gguf';
    final modelFile = File(modelPath);

    if (!await modelFile.exists()) {
      throw Exception(
        'Model not found at $modelPath.\n'
        'Please download Llama-3.2-3B-Instruct-Q4_K_M.gguf and place it in the app documents directory.',
      );
    }

    _isLlama = modelPath.toLowerCase().contains('llama');

    final backend = LlamaBackend();
    _engine = LlamaEngine(backend);
    
    await _engine!.loadModel(
      modelPath,
      modelParams: const ModelParams(
        contextSize: 4096,
        cacheTypeK: KvCacheType.q8_0,
        cacheTypeV: KvCacheType.q8_0,
      ),
    );

    _isInitialized = true;
  }

  static Future<List<String>> generateSubQueries(String query) async {
    if (!_isInitialized || _engine == null) return [query];
    
    final instruction = 
        'List 3 or 4 core technical sub-topics or mechanisms a textbook covers to explain this question, separated by commas. Do not write anything else.\n\n'
        'Question: $query';

    final prompt = _isLlama
        ? '<|begin_of_text|><|start_header_id|>user<|end_header_id|>\n\n$instruction<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n'
        : '<bos><start_of_turn>user\n$instruction<end_of_turn>\n<start_of_turn>model\n';
    
    final stopSequences = _isLlama
        ? ['<|eot_id|>', '<|end_of_text|>']
        : ['<end_of_turn>', '<eos>'];
    
    String result = "";
    int tokens = 0;
    try {
      await for (final chunk in _engine!.generate(
        prompt, 
        params: GenerationParams(
          temp: 0.1, 
          maxTokens: 50,
          stopSequences: stopSequences,
        ),
      )) {
        result += chunk;
        tokens++;
        if (tokens > 50) break;
      }
    } catch (e) {
      print('Sub-query generation error: $e');
    }
    
    print('RAG: Raw sub-query output: "$result"');
    final parts = result
        .split(RegExp(r'[,;\n]'))
        .map((s) => s.trim().replaceAll(RegExp(r'^[0-9\.\-\*\s]+'), '').replaceAll(RegExp(r'[^\w\s]'), ' ').trim())
        .where((s) => s.length > 2)
        .toList();
        
    print('RAG: Decomposed sub-queries: $parts');
    if (parts.isEmpty) return [query];
    return [query, ...parts.take(3)];
  }

  static Stream<String> generateResponse(List<ChatMessage> history, {List<String>? contextChunks}) async* {
    if (!_isInitialized || _engine == null) {
      throw Exception('LLM not initialized');
    }

    String systemText = '''You are the expert generation engine for NotebookPRO. Write a faithful, concise, and academically objective answer. Shorter is fine if the excerpts are limited.

STRICT GROUNDING: You MUST ONLY use information present inside the provided context. Do NOT use outside knowledge and do NOT hallucinate.

REQUIRED OUTPUT STRUCTURE:
- Use clear markdown headings with ### for major sections.
- Use bulleted breakdowns with bold key terms.
- If a technical term is named in the context, explain what it does in one short sentence using the context. If the context gives no explanation for that term, state briefly that its mechanism is not detailed in the excerpts.
- Keep explanations dense, objective, and structured.
- Do NOT use conversational or textbook tutorial voice (avoid words like "our", "we", "this chapter", "earlier", or "later").
- Never treat chapter summaries, book previews, or a table of contents as technical explanation.
- If the excerpts do not contain substantive technical explanation for the question, reply in one or two concise sentences stating what the excerpts do and do not cover, rather than expanding on titles or blurbs.
- Do NOT output chapter reference pointers or forward-looking statements like "Chapter 5 covers architecture" or "discussed in Chapter 3". Only state technical facts directly explained in the excerpts.

**Citation Rules:**
- Every factual sentence must be supported by a citation **[1]**.
- Citations must be inline and numeric only: **[n]** or **[n, m]**.
- Paraphrase facts and cite them. Do NOT make up information.

CORRECT CITATION FORMAT: "Kubernetes uses a declarative model [1]."
INCORRECT CITATION FORMAT: "According to Source [1], Kubernetes uses a declarative model."''';

    final buffer = StringBuffer();
    if (_isLlama) {
      buffer.write('<|begin_of_text|>');
    } else {
      buffer.write('<bos>');
    }

    int lastUserIndex = history.lastIndexWhere((msg) => msg.role == 'user');

    for (int i = 0; i < history.length; i++) {
      var msg = history[i];
      if (msg.role == 'assistant' && msg.content.isEmpty) continue;
      
      String text = msg.content;
      
      if (i == lastUserIndex) {
        if (contextChunks != null && contextChunks.isNotEmpty) {
          text = '''$systemText

**===== START OF CONTEXT =====**

${contextChunks.join('\n\n')}

**===== END OF CONTEXT =====**

**Student's Question:** $text

**Instructions:** Answer ONLY using the context between the markers above. For each technical term, explain what it does in one short sentence using the context. Cite sources in brackets.''';
        } else {
          text = '$systemText\n\n$text';
        }
      }

      if (_isLlama) {
        final role = (msg.role == 'assistant' || msg.role == 'model') ? 'assistant' : 'user';
        buffer.write('<|start_header_id|>$role<|end_header_id|>\n\n$text<|eot_id|>');
      } else {
        final role = (msg.role == 'assistant' || msg.role == 'model') ? 'model' : 'user';
        buffer.write('<start_of_turn>$role\n$text<end_of_turn>\n');
      }
    }
    
    // Start assistant/model response
    if (_isLlama) {
      buffer.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
    } else {
      buffer.write('<start_of_turn>model\n');
    }
    
    final fullPrompt = buffer.toString();
    print('\n================ EXACT LLM PROMPT DUMP FOR EXPERT TEST ================');
    for (var i = 0; i < fullPrompt.length; i += 800) {
      int end = (i + 800 < fullPrompt.length) ? i + 800 : fullPrompt.length;
      print(fullPrompt.substring(i, end));
    }
    print('=========================================================================\n');

    print('LLM: Starting generation with context size ${history.length} messages (${_isLlama ? "Llama 3 Template" : "Gemma Native Template"})');
    final startTime = DateTime.now();
    int tokenCount = 0;
    
    await for (final textChunk in _engine!.generate(
      buffer.toString(),
      params: GenerationParams(
        temp: 0.1,
        maxTokens: 800,
        stopSequences: _isLlama
            ? const ['<|eot_id|>', '<|end_of_text|>']
            : const ['<end_of_turn>', '<eos>'],
      ),
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

