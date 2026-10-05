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
    final modelPath = '${docDir.path}/qwen2.5-1.5b-instruct-q4_k_m.gguf';
    final modelFile = File(modelPath);

    if (!await modelFile.exists()) {
      throw Exception(
        'Model not found at $modelPath.\n'
        'Please download Qwen2.5 1.5B Q4_K_M GGUF and place it in the app documents directory.',
      );
    }

    final backend = LlamaBackend();
    _engine = LlamaEngine(backend);
    
    await _engine!.loadModel(
      modelPath,
      modelParams: const ModelParams(
        contextSize: 8192,
      ),
    );

    _isInitialized = true;
  }

  static Stream<String> generateResponse(List<ChatMessage> history, {List<String>? contextChunks}) async* {
    if (!_isInitialized || _engine == null) {
      throw Exception('LLM not initialized');
    }

    String systemText = '''You are the expert generation engine for NotebookPRO, an advanced academic study system for Master-level data science and NLP coursework. Your goal is to synthesize retrieved textbook excerpts into rigorous, mathematically sound, comprehensive study material.

STRICT GROUNDING: You MUST ONLY use information present inside the provided context. Do NOT use outside knowledge and do NOT hallucinate. Every technical claim must be traceable to context.

TEMPORAL ARBITRATION & SYNTHESIS: Context chunks are labeled as Source [i] [YEAR: YYYY] (filename). Prioritize the most recent year as modern standard/state-of-the-art, and frame older sources as foundational/historical context.

ACADEMIC RIGOR: Avoid superficial summaries. Explain mechanisms, formulas, penalties, architectural details, limitations, and failure modes when present.

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

**Citation Rules:**
- Cite every major claim or paragraph using **[1]**, **[2]** etc based on Source number.
- If claim uses multiple sources, use **[1, 2]**.
- Citations must be numeric only: **[n]** or **[n, m]**.
- NEVER include year, filename, or the word Source in citation text.
- Do NOT make up information.''';

    final messages = [
      LlamaChatMessage.fromText(role: LlamaChatRole.system, text: systemText),
    ];
    
    for (int i = 0; i < history.length; i++) {
      var msg = history[i];
      // Don't include the empty assistant message that is currently being generated
      if (msg.role == 'assistant' && msg.content.isEmpty) continue;
      
      String text = msg.content;
      
      if (msg.role == 'user' && i == history.length - 2 && contextChunks != null && contextChunks.isNotEmpty) {
        text = '''**===== START OF CONTEXT (ANSWER ONLY FROM THIS) =====**

${contextChunks.join('\n\n')}

**===== END OF CONTEXT =====**

**Student's Question:** $text

**Instructions:** Answer ONLY using the context between the markers above. If the context does not contain the answer, say you do not have that information. Cite sources in brackets.

**Academic Completeness Checklist (apply when evidence exists in context):**
1. Include core mechanism details, not just definitions.
2. Include at least one relevant equation, formula component, or scoring term when present.
3. State known limitations/failure cases and why they matter.
4. Mention important variants/versions when supported by context.
5. Briefly contrast with modern alternatives if context includes them.
6. Synthesize evidence from multiple source snippets when available.
7. Keep structure clear: definition -> mechanics -> limitations -> modern view -> takeaway.
Note: If a checklist item is not supported by the provided context, explicitly say that.''';
      }

      messages.add(LlamaChatMessage.fromText(
        role: msg.role == 'user' ? LlamaChatRole.user : LlamaChatRole.assistant, 
        text: text,
      ));
    }
    
    await for (final chunk in _engine!.create(messages)) {
      if (chunk.choices.isNotEmpty) {
        final text = chunk.choices.first.delta.content;
        if (text != null && text.isNotEmpty) {
          yield text;
        }
      }
    }
  }

  static void dispose() {
    _engine?.dispose();
    _engine = null;
    _isInitialized = false;
  }
}

