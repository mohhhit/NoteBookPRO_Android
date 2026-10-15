import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_litert_lm/flutter_litert_lm.dart';
import 'package:llamadart/llamadart.dart';

import '../models/app_models.dart';
import 'prompt_builder.dart';

class LocalModelInfo {
  final bool isInitialized;
  final String activeEngine;
  final String activeModelName;
  final String activeModelFilename;
  final double activeModelSizeMb;
  final bool modelExists;
  final bool isDownloading;
  final double partialDownloadMb;
  final bool isRerankerReady;
  final double rerankerSizeMb;
  final bool isVocabReady;

  const LocalModelInfo({
    required this.isInitialized,
    required this.activeEngine,
    required this.activeModelName,
    required this.activeModelFilename,
    required this.activeModelSizeMb,
    required this.modelExists,
    required this.isDownloading,
    required this.partialDownloadMb,
    required this.isRerankerReady,
    required this.rerankerSizeMb,
    required this.isVocabReady,
  });
}

class LocalLlmService {
  static LiteLmEngine? _liteLmEngine;
  static LlamaEngine? _llamaEngine;
  static bool _isInitialized = false;
  static bool _isLiteLm = false;
  static bool _isLlama = false;
  static bool lastHitTokenLimit = false;

  /// Returns detailed information about on-device AI models and storage.
  static Future<LocalModelInfo> getModelInfo() async {
    final docDir = await getApplicationDocumentsDirectory();
    final e2bFile = File('${docDir.path}/gemma-4-E2B-it.litertlm');
    final e2bPartFile = File('${docDir.path}/gemma-4-E2B-it.litertlm.part');
    final e4bFile = File('${docDir.path}/gemma-4-E4B-it.litertlm');
    final ggufFile = File('${docDir.path}/Llama-3.2-3B-Instruct-Q4_K_M.gguf');
    final rerankerFile = File('${docDir.path}/ms-marco-MiniLM-L-6-v2-quantized.onnx');
    final vocabFile = File('${docDir.path}/ms-marco-MiniLM-vocab.txt');

    String activeEngine = 'Uninitialized';
    String activeModelName = 'Not Found';
    String activeModelFilename = '';
    double activeModelSizeMb = 0.0;
    bool modelExists = false;

    if (await e2bFile.exists()) {
      modelExists = true;
      activeModelName = 'Gemma 4 E2B';
      activeModelFilename = 'gemma-4-E2B-it.litertlm';
      activeModelSizeMb = (await e2bFile.length()) / (1024 * 1024);
      activeEngine = _isLiteLm ? 'Google LiteRT-LM (CPU)' : 'LiteRT-LM Ready';
    } else if (await e4bFile.exists()) {
      modelExists = true;
      activeModelName = 'Gemma 4 E4B';
      activeModelFilename = 'gemma-4-E4B-it.litertlm';
      activeModelSizeMb = (await e4bFile.length()) / (1024 * 1024);
      activeEngine = _isLiteLm ? 'Google LiteRT-LM (CPU)' : 'LiteRT-LM Ready';
    } else if (await ggufFile.exists()) {
      modelExists = true;
      activeModelName = 'Llama 3.2 3B';
      activeModelFilename = 'Llama-3.2-3B-Instruct-Q4_K_M.gguf';
      activeModelSizeMb = (await ggufFile.length()) / (1024 * 1024);
      activeEngine = _isLlama ? 'llama.cpp GGUF' : 'llama.cpp Ready';
    }

    bool isDownloading = false;
    double partialDownloadMb = 0.0;
    if (!modelExists && await e2bPartFile.exists()) {
      isDownloading = true;
      partialDownloadMb = (await e2bPartFile.length()) / (1024 * 1024);
    }

    final rerankerReady = await rerankerFile.exists() && (await rerankerFile.length()) > 5 * 1024 * 1024;
    final rerankerSizeMb = rerankerReady ? (await rerankerFile.length()) / (1024 * 1024) : 0.0;
    final vocabReady = await vocabFile.exists() && (await vocabFile.length()) > 1000;

    return LocalModelInfo(
      isInitialized: _isInitialized,
      activeEngine: _isInitialized ? (_isLiteLm ? 'Google LiteRT-LM (CPU)' : 'llama.cpp') : activeEngine,
      activeModelName: activeModelName,
      activeModelFilename: activeModelFilename,
      activeModelSizeMb: activeModelSizeMb,
      modelExists: modelExists,
      isDownloading: isDownloading,
      partialDownloadMb: partialDownloadMb,
      isRerankerReady: rerankerReady,
      rerankerSizeMb: rerankerSizeMb,
      isVocabReady: vocabReady,
    );
  }

  static Future<void> initialize() async {
    if (_isInitialized) return;

    final docDir = await getApplicationDocumentsDirectory();
    final e2bPath = '${docDir.path}/gemma-4-E2B-it.litertlm';
    final e2bFile = File(e2bPath);
    final e4bPath = '${docDir.path}/gemma-4-E4B-it.litertlm';
    final e4bFile = File(e4bPath);

    final ggufPath = '${docDir.path}/Llama-3.2-3B-Instruct-Q4_K_M.gguf';
    final ggufFile = File(ggufPath);

    // 1. Prioritize Google LiteRT-LM (Gemma 4 E2B, with E4B fallback if present)
    final litertPath = (await e2bFile.exists())
        ? e2bPath
        : ((await e4bFile.exists()) ? e4bPath : null);

    if (litertPath != null) {
      debugPrint('[LocalLlmService] Found LiteRT-LM model at $litertPath');
      debugPrint('[LocalLlmService] Initializing LiteRT-LM with CPU (XNNPACK) backend...');
      _liteLmEngine = await LiteLmEngine.create(
        LiteLmEngineConfig(
          modelPath: litertPath,
          backend: LiteLmBackend.cpu,
        ),
      );
      debugPrint('[LocalLlmService] LiteRT-LM successfully initialized with CPU backend.');

      _isLiteLm = true;
      _isInitialized = true;
      return;
    }

    // 2. Fallback to llama.cpp GGUF engine if legacy model exists
    if (await ggufFile.exists()) {
      debugPrint('[LocalLlmService] Found legacy GGUF model at $ggufPath');
      _isLlama = ggufPath.toLowerCase().contains('llama');

      final backend = LlamaBackend();
      _llamaEngine = LlamaEngine(backend);

      await _llamaEngine!.loadModel(
        ggufPath,
        modelParams: const ModelParams(
          contextSize: 4096,
          cacheTypeK: KvCacheType.q8_0,
          cacheTypeV: KvCacheType.q8_0,
        ),
      );

      _isLiteLm = false;
      _isInitialized = true;
      return;
    }

    throw Exception(
      'Model not found.\n'
      'Expected LiteRT-LM model at: $e2bPath\n'
      'Please let the app download gemma-4-E2B-it.litertlm.',
    );
  }

  static AnswerUseCase inferUseCase(String query) => PromptBuilder.inferUseCase(query);

  static Stream<String> generateResponse(
    List<ChatMessage> history, {
    List<String>? contextChunks,
    AnswerUseCase? explicitUseCase,
  }) async* {
    if (!_isInitialized || (_liteLmEngine == null && _llamaEngine == null)) {
      throw Exception('LLM not initialized');
    }

    final safeChunks = contextChunks ?? const [];
    final lastUserMsg = history.lastWhere((msg) => msg.role == 'user', orElse: () => history.last);
    final userQuery = lastUserMsg.content;
    final uc = explicitUseCase ?? PromptBuilder.inferUseCase(userQuery);
    final scope = PromptBuilder.extractScopePhrase(userQuery);

    final preparedChunks = PromptBuilder.prepareChunks(safeChunks, userQuery);
    final systemText = PromptBuilder.buildSystemPrompt(uc, chunks: preparedChunks, scope: scope);
    final userPromptText = PromptBuilder.buildUserMessage(userQuery, preparedChunks, uc, scope: scope);

    final approxPromptTokens = ((systemText.length + userPromptText.length) / 3.8).round();

    print('\n================ EXACT LLM PROMPT DUMP (use_case=$uc, scope=$scope, engine=${_isLiteLm ? "LiteRT-LM" : "LlamaCpp"}) ================');
    print('[LLM_TIMING] estimated_prompt_tokens=~$approxPromptTokens history_turns=${history.length}');
    print('--- SYSTEM INSTRUCTION ---');
    print(systemText);
    print('--- USER PROMPT ---');
    print(userPromptText);
    print('========================================================================================================\n');

    final startTime = DateTime.now();
    DateTime? firstTokenTime;
    int tokenCount = 0;
    lastHitTokenLimit = false;

    // === PATH 1: LiteRT-LM INFERENCE (Gemma 4 E4B) ===
    if (_isLiteLm && _liteLmEngine != null) {
      // Build prior history messages (excluding final turn which is sent via stream)
      final initialMessages = <LiteLmMessage>[];
      int lastUserIndex = history.lastIndexWhere((msg) => msg.role == 'user');

      for (int i = 0; i < history.length; i++) {
        if (i == lastUserIndex) continue;
        final msg = history[i];
        if (msg.content.isEmpty) continue;

        if (msg.role == 'assistant' || msg.role == 'model') {
          initialMessages.add(LiteLmMessage.model(msg.content));
        } else if (msg.role == 'user') {
          initialMessages.add(LiteLmMessage.user(msg.content));
        }
      }

      final conversation = await _liteLmEngine!.createConversation(
        LiteLmConversationConfig(
          systemInstruction: systemText,
          initialMessages: initialMessages.isNotEmpty ? initialMessages : null,
          samplerConfig: const LiteLmSamplerConfig(
            temperature: 0.35,
            topK: 40,
            topP: 0.90,
          ),
        ),
      );

      try {
        await for (final delta in conversation.sendMessageStream(userPromptText)) {
          if (tokenCount == 0) {
            firstTokenTime = DateTime.now();
            final prefillMs = firstTokenTime.difference(startTime).inMilliseconds;
            final prefillSpeed = (approxPromptTokens / (math.max(1, prefillMs) / 1000)).toStringAsFixed(1);
            print('[LLM_TIMING] first_token_ms=$prefillMs (~$prefillSpeed prefill tok/s)');
          }

          if (delta.text.isNotEmpty) {
            tokenCount++;
            yield delta.text;
          }
        }
      } finally {
        await conversation.dispose();
      }

      if (tokenCount >= 780) {
        lastHitTokenLimit = true;
      }

      final totalElapsedMs = DateTime.now().difference(startTime).inMilliseconds;
      final decodeMs = firstTokenTime != null ? DateTime.now().difference(firstTokenTime).inMilliseconds : 1;
      final decodeSpeed = tokenCount / (decodeMs / 1000.0);
      print('[LLM_TIMING] generation_done total_ms=$totalElapsedMs decode_tokens=$tokenCount decode_speed=${decodeSpeed.toStringAsFixed(1)} tok/s');
      return;
    }

    // === PATH 2: llama.cpp INFERENCE (GGUF FALLBACK) ===
    final buffer = StringBuffer();
    if (_isLlama) {
      buffer.write('<|begin_of_text|>');
      buffer.write('<|start_header_id|>system<|end_header_id|>\n\n$systemText<|eot_id|>');
    } else {
      buffer.write('<bos>');
      buffer.write('<start_of_turn>system\n$systemText<end_of_turn>\n');
    }

    int lastUserIndex = history.lastIndexWhere((msg) => msg.role == 'user');
    for (int i = 0; i < history.length; i++) {
      var msg = history[i];
      if (msg.role == 'assistant' && msg.content.isEmpty) continue;

      String text = msg.content;
      if (i == lastUserIndex) {
        text = userPromptText;
      }

      final role = (msg.role == 'assistant' || msg.role == 'model') ? 'assistant' : 'user';
      if (_isLlama) {
        buffer.write('<|start_header_id|>$role<|end_header_id|>\n\n$text<|eot_id|>');
      } else {
        final gRole = (role == 'assistant') ? 'model' : 'user';
        buffer.write('<start_of_turn>$gRole\n$text<end_of_turn>\n');
      }
    }

    if (_isLlama) {
      buffer.write('<|start_header_id|>assistant<|end_header_id|>\n\n');
    } else {
      buffer.write('<start_of_turn>model\n');
    }

    final fullPrompt = buffer.toString();

    await for (final textChunk in _llamaEngine!.generate(
      fullPrompt,
      params: GenerationParams(
        temp: 0.35,
        maxTokens: 1000,
        stopSequences: _isLlama
            ? const ['<|eot_id|>', '<|end_of_text|>']
            : const ['<end_of_turn>', '<eos>'],
      ),
    )) {
      if (tokenCount == 0) {
        firstTokenTime = DateTime.now();
        final prefillMs = firstTokenTime.difference(startTime).inMilliseconds;
        final prefillSpeed = (approxPromptTokens / (math.max(1, prefillMs) / 1000)).toStringAsFixed(1);
        print('[LLM_TIMING] first_token_ms=$prefillMs (~$prefillSpeed prefill tok/s)');
      }

      if (textChunk.isNotEmpty) {
        tokenCount++;
        yield textChunk;
      }
    }

    if (tokenCount >= 780) {
      lastHitTokenLimit = true;
    }

    final totalElapsedMs = DateTime.now().difference(startTime).inMilliseconds;
    final decodeMs = firstTokenTime != null ? DateTime.now().difference(firstTokenTime).inMilliseconds : 1;
    final decodeSpeed = tokenCount / (decodeMs / 1000.0);
    print('[LLM_TIMING] generation_done total_ms=$totalElapsedMs decode_tokens=$tokenCount decode_speed=${decodeSpeed.toStringAsFixed(1)} tok/s');
  }

  static void dispose() {
    _liteLmEngine?.dispose();
    _liteLmEngine = null;
    _llamaEngine?.dispose();
    _llamaEngine = null;
    _isInitialized = false;
  }
}
