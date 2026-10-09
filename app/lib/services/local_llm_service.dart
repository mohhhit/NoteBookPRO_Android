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
    final modelPath = '${docDir.path}/Llama-3.2-3B-Instruct-Q4_K_M.gguf';
    final modelFile = File(modelPath);

    if (!await modelFile.exists()) {
      throw Exception(
        'Model not found at $modelPath.\n'
        'Please download Llama-3.2-3B-Instruct-Q4_K_M GGUF and place it in the app documents directory.',
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

    String systemText = '''You are the expert generation engine for NotebookPRO, an advanced academic study system for Master-level data science and NLP coursework. Your goal is to synthesize retrieved textbook excerpts into rigorous, mathematically sound, comprehensive study material.

STRICT GROUNDING: You MUST ONLY use information present inside the provided context. Do NOT use outside knowledge and do NOT hallucinate. Every technical claim must be traceable to context.

TEMPORAL ARBITRATION & SYNTHESIS: Context chunks are labeled as Source [i] [YEAR: YYYY] (filename). Prioritize the most recent year as modern standard/state-of-the-art, and frame older sources as foundational/historical context.

ACADEMIC RIGOR: Avoid superficial summaries. Only include limitations, failure modes, or formulas if they are explicitly detailed in the excerpts. If the excerpts only explain what a tool does, omit those sections entirely.

REQUIRED OUTPUT STRUCTURE:
- Use clear markdown headings with ### for major sections.
- Use bulleted breakdowns with bold key terms (for example, * **Mechanism:** ...).
- For tabular values, use valid markdown tables: header row, separator row (---), then body rows.
- Keep explanations dense, structured, and exam-ready.
- Do not add UI extras like Suggested Follow-Up Questions inside the answer body.

**Your task:** Answer the question directly and comprehensively.
- Provide the direct answer immediately in the first sentence.
- Build a deep explanation using multiple complementary points from context.
- When question asks why, include mechanisms, risks, impacts, and implementation implications if present.
- Use numbered lists or bullet points for supporting details when useful.
- Use **bold** for key facts, numbers, and formulas.
- Aim for substantial depth (typically 250-500 words) unless context is very limited.

**Citation Rules & Examples:**
- Every factual sentence must be supported by a citation **[1]**.
- If you mention a standard concept not explicitly explained in the text, you must prefix it with 'Generally in practice' or omit it.
- Cite every major claim or paragraph using **[1]**, **[2]** etc based on Source number.
- If claim uses multiple sources, use **[1, 2]**.
- Citations must be inline and numeric only: **[n]** or **[n, m]**.
- Paraphrase facts and cite them. Do NOT make up information.

CORRECT CITATION FORMAT: "Kubernetes uses a declarative model [1]."
INCORRECT CITATION FORMAT: "According to Source [1], Kubernetes uses a declarative model."
INCORRECT CITATION FORMAT: "**Source [1]:** Kubernetes uses a declarative model."''';

    final buffer = StringBuffer();
    buffer.writeln('<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n$systemText<|eot_id|>');

    int lastUserIndex = history.lastIndexWhere((msg) => msg.role == 'user');

    for (int i = 0; i < history.length; i++) {
      var msg = history[i];
      if (msg.role == 'assistant' && msg.content.isEmpty) continue;
      
      String text = msg.content;
      
      if (i == lastUserIndex && contextChunks != null && contextChunks.isNotEmpty) {
        text = '''**===== START OF CONTEXT (ANSWER ONLY FROM THIS) =====**

${contextChunks.join('\n\n')}

**===== END OF CONTEXT =====**

**Student's Question:** $text

**Instructions:** Answer ONLY using the context between the markers above. If the context does not contain the answer, say you do not have that information. Cite sources in brackets.

**Academic Completeness Checklist (apply ONLY when evidence exists in context):**
1. Include core mechanism details, not just definitions.
2. Include at least one relevant equation, formula component, or scoring term when present.
3. State known limitations/failure cases and why they matter.
4. Mention important variants/versions when supported by context.
5. Synthesize evidence from multiple source snippets when available.
6. Keep structure clear: definition -> mechanics -> limitations -> takeaway.

**CRITICAL ANTI-HALLUCINATION RULES:**
- Do NOT mention "alternatives" unless the context explicitly compares them as competing technologies. Auxiliary tools mentioned in passing are NOT alternatives.
- Do NOT invent information or equations. If an item above is missing from context, omit it entirely.''';
      }

      buffer.writeln('<|start_header_id|>${msg.role}<|end_header_id|>\n\n$text<|eot_id|>');
    }
    
    // Start assistant response
    buffer.write('<|start_header_id|>assistant<|end_header_id|>\n\n');

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

