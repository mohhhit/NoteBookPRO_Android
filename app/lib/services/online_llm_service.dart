import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_models.dart';
import 'prompt_builder.dart';

class OnlineLlmService {
  static const String defaultModel = 'gemini-3.5-flash-lite';

  static const List<Map<String, String>> supportedModels = [
    {
      'id': 'gemini-3.5-flash-lite',
      'name': 'gemini3.5-flash-lite',
      'shortName': 'gemini3.5-flash-lite',
    },
  ];

  /// Retrieves the saved Google AI Studio API key from local preferences.
  static Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('gemini_api_key');
  }

  /// Saves the Google AI Studio API key to local preferences.
  static Future<void> setApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_api_key', key.trim());
  }

  /// Retrieves the selected Online Gemini model identifier.
  static Future<String> getSelectedModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('gemini_model_name') ?? defaultModel;
  }

  /// Saves the selected Online Gemini model identifier.
  static Future<void> setSelectedModel(String model) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('gemini_model_name', model);
  }

  /// Returns a clean, user-friendly display name for the model id.
  static String getModelDisplayName(String modelId) {
    for (final m in supportedModels) {
      if (m['id'] == modelId) return m['shortName']!;
    }
    return modelId;
  }

  /// Returns candidate model name variations for robust API matching
  static List<String> _candidateModelNames(String model) {
    final list = <String>[model];
    if (model == 'gemini-3.5-flash-lite') {
      list.add('gemini3.5-flash-lite');
    } else if (model == 'gemini3.5-flash-lite') {
      list.add('gemini-3.5-flash-lite');
    }
    return list;
  }

  /// Verifies whether the provided API key is valid by sending a minimal ping request.
  static Future<Map<String, dynamic>> testApiKey(String apiKey, {String model = defaultModel}) async {
    final candidates = _candidateModelNames(model);
    String lastError = '';

    for (final candidate in candidates) {
      try {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$candidate:generateContent?key=$apiKey',
        );
        final response = await http.post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'contents': [
              {
                'parts': [
                  {'text': 'Hello'}
                ]
              }
            ],
            'generationConfig': {'maxOutputTokens': 5}
          }),
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          return {'success': true, 'message': 'API key verified with $candidate'};
        } else if (response.statusCode == 404) {
          lastError = 'Model $candidate not found (404)';
          continue; // Try next candidate
        } else {
          String detail = 'Status ${response.statusCode}';
          try {
            final errJson = jsonDecode(response.body);
            if (errJson['error']?['message'] != null) {
              detail = errJson['error']['message'];
            }
          } catch (_) {}
          return {'success': false, 'message': detail};
        }
      } catch (e) {
        lastError = 'Connection error: $e';
      }
    }
    return {'success': false, 'message': lastError};
  }

  /// Streams token-by-token response from Google AI Studio Gemini API via SSE,
  /// formatting the exact same context chunks and prompt scaffolding as the local LLM.
  static Stream<String> generateResponse(
    List<ChatMessage> history, {
    List<String>? contextChunks,
    AnswerUseCase? explicitUseCase,
    String? modelName,
    required String apiKey,
  }) async* {
    if (apiKey.trim().isEmpty) {
      throw Exception(
        'Google AI Studio API key not found. Please configure your key in Settings or the model switcher.',
      );
    }

    final model = (modelName != null && modelName.isNotEmpty) ? modelName : defaultModel;
    final safeChunks = contextChunks ?? const [];
    final lastUserMsg = history.lastWhere((msg) => msg.role == 'user', orElse: () => history.last);
    final userQuery = lastUserMsg.content;
    final uc = explicitUseCase ?? PromptBuilder.inferUseCase(userQuery);

    // Build the identical prompt structure used by the local on-device pipeline
    final preparedChunks = PromptBuilder.prepareChunks(safeChunks, userQuery);
    final systemText = PromptBuilder.buildSystemPrompt(uc, chunks: preparedChunks);
    final userPromptText = PromptBuilder.buildUserMessage(userQuery, preparedChunks, uc);

    print('\n================ EXACT ONLINE GEMINI PROMPT DUMP (model=$model, use_case=$uc) ================');
    print('--- SYSTEM INSTRUCTION ---');
    print(systemText);
    print('--- USER PROMPT ---');
    print(userPromptText);
    print('=================================================================================================\n');

    final contents = <Map<String, dynamic>>[];
    int lastUserIndex = history.lastIndexWhere((msg) => msg.role == 'user');

    for (int i = 0; i < history.length; i++) {
      if (i == lastUserIndex) continue;
      final msg = history[i];
      if (msg.content.trim().isEmpty) continue;
      final role = (msg.role == 'assistant' || msg.role == 'model') ? 'model' : 'user';
      contents.add({
        'role': role,
        'parts': [{'text': msg.content}],
      });
    }

    contents.add({
      'role': 'user',
      'parts': [{'text': userPromptText}],
    });

    final requestBody = jsonEncode({
      'contents': contents,
      'systemInstruction': {
        'parts': [{'text': systemText}],
      },
      'generationConfig': {
        'temperature': 0.35,
        'topK': 40,
        'topP': 0.90,
        'maxOutputTokens': 2048,
      },
    });

    final client = http.Client();
    final candidates = _candidateModelNames(model);
    http.StreamedResponse? streamedResponse;

    try {
      for (final candidate in candidates) {
        final url = Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/$candidate:streamGenerateContent?alt=sse&key=$apiKey',
        );
        final request = http.Request('POST', url)
          ..headers['Content-Type'] = 'application/json'
          ..body = requestBody;

        final resp = await client.send(request);
        if (resp.statusCode == 404 && candidate != candidates.last) {
          // Try alternate candidate name if first gave 404
          continue;
        }
        streamedResponse = resp;
        break;
      }

      if (streamedResponse == null || streamedResponse.statusCode != 200) {
        final statusCode = streamedResponse?.statusCode ?? 500;
        final errBody = streamedResponse != null ? await streamedResponse.stream.bytesToString() : 'No response';
        String errorMsg = 'Gemini API Error ($statusCode)';
        try {
          final errJson = jsonDecode(errBody);
          if (errJson['error'] != null && errJson['error']['message'] != null) {
            errorMsg = 'Gemini API: ${errJson['error']['message']}';
          }
        } catch (_) {
          errorMsg = 'Gemini API: $errBody';
        }
        throw Exception(errorMsg);
      }

      final lineStream = streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lineStream) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('data:')) continue;
        final jsonStr = trimmed.substring(5).trim();
        if (jsonStr.isEmpty || jsonStr == '[DONE]') continue;

        try {
          final data = jsonDecode(jsonStr);
          final candidates = data['candidates'] as List?;
          if (candidates != null && candidates.isNotEmpty) {
            final content = candidates[0]['content'];
            if (content != null) {
              final parts = content['parts'] as List?;
              if (parts != null) {
                for (final part in parts) {
                  final text = part['text'] as String?;
                  if (text != null && text.isNotEmpty) {
                    yield text;
                  }
                }
              }
            }
          }
        } catch (_) {
          // ignore partial chunks
        }
      }
    } finally {
      client.close();
    }
  }
}

