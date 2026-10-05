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
        contextSize: 2048,
      ),
    );

    _isInitialized = true;
  }

  static Stream<String> generateResponse(List<ChatMessage> history, {List<String>? contextChunks}) async* {
    if (!_isInitialized || _engine == null) {
      throw Exception('LLM not initialized');
    }

    String systemText = 'You are NotebookPRO AI, a helpful studying assistant.';
    if (contextChunks != null && contextChunks.isNotEmpty) {
      systemText += '\n\nUse the following context to answer the user:\n\n';
      systemText += contextChunks.join('\n\n');
    }

    final messages = [
      LlamaChatMessage.fromText(role: LlamaChatRole.system, text: systemText),
    ];
    
    for (var msg in history) {
      // Don't include the empty assistant message that is currently being generated
      if (msg.role == 'assistant' && msg.content.isEmpty) continue;
      
      messages.add(LlamaChatMessage.fromText(
        role: msg.role == 'user' ? LlamaChatRole.user : LlamaChatRole.assistant, 
        text: msg.content,
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

