import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiService {
  // Default backend URL (can be changed in settings)
  static String _baseUrl = 'http://localhost:8011';

  // Initialize baseUrl from storage
  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('backend_url') ?? 'http://localhost:8011';
  }

  // Get current backend URL
  static Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('backend_url') ?? _baseUrl;
  }

  // Set backend URL
  static Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backend_url', url);
    _baseUrl = url;
  }

  // Get base URL synchronously (uses cached value)
  static String get baseUrl => _baseUrl;

  static bool _isLocalTunnelUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == 'loca.lt' || host.endsWith('.loca.lt');
  }

  static Map<String, String> buildHeaders({
    String? baseUrl,
    Map<String, String>? extra,
  }) {
    final headers = <String, String>{};
    if (extra != null) {
      headers.addAll(extra);
    }

    final effectiveBaseUrl = baseUrl ?? _baseUrl;
    if (_isLocalTunnelUrl(effectiveBaseUrl)) {
      // Bypasses LocalTunnel's anti-phishing interstitial for API requests.
      headers['bypass-tunnel-reminder'] = 'true';
    }

    return headers;
  }

  static String formatHttpError({
    required String operation,
    required http.Response response,
  }) {
    final body = response.body;

    if (response.statusCode == 511 ||
        body.contains('Tunnel website ahead') ||
        body.contains('bypass-tunnel-reminder')) {
      return '$operation failed: LocalTunnel blocked this API request (HTTP 511). '
          'Use your .loca.lt URL and retry. If the issue persists, restart the app so new headers are applied.';
    }

    if (body.contains('<html') || body.contains('<!DOCTYPE html')) {
      return '$operation failed: server returned HTML instead of JSON (HTTP ${response.statusCode}). '
          'Check backend URL and tunnel state.';
    }

    if (body.length > 600) {
      return '$operation failed with HTTP ${response.statusCode}. '
          'Server response was too long to display.';
    }

    return '$operation failed (HTTP ${response.statusCode}): $body';
  }

  // Test connection to backend
  static Future<bool> testConnection(String url) async {
    try {
      final healthResponse = await http
          .get(
            Uri.parse('$url/api/health'),
            headers: buildHeaders(baseUrl: url),
          )
          .timeout(const Duration(seconds: 3));

      if (healthResponse.statusCode == 200) {
        return true;
      }

      if (healthResponse.statusCode == 404) {
        final legacyResponse = await http
            .get(
              Uri.parse('$url/api/spaces'),
              headers: buildHeaders(baseUrl: url),
            )
            .timeout(const Duration(seconds: 3));
        return legacyResponse.statusCode == 200;
      }

      return false;
    } catch (e) {
      return false;
    }
  }

  // ==================== Spaces ====================

  Future<List<Space>> getSpaces() async {
    final url = await ApiService.getBaseUrl();
    final response = await http.get(
      Uri.parse('$url/api/spaces'),
      headers: ApiService.buildHeaders(baseUrl: url),
    );

    if (response.statusCode == 200) {
      List<dynamic> data = json.decode(response.body);
      return data.map((json) => Space.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load spaces');
    }
  }

  Future<Space> createSpace(String name) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/spaces'),
      headers: ApiService.buildHeaders(
        baseUrl: url,
        extra: {'Content-Type': 'application/json'},
      ),
      body: json.encode({'name': name}),
    );

    if (response.statusCode == 200) {
      return Space.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to create space');
    }
  }

  Future<void> deleteSpace(String spaceId) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.delete(
      Uri.parse('$url/api/spaces/$spaceId'),
      headers: ApiService.buildHeaders(baseUrl: url),
    );

    if (response.statusCode != 200) {
      // Try to extract error message from response
      String errorMessage = 'Failed to delete space';
      try {
        final errorData = json.decode(response.body);
        if (errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {
        // Keep default error message
      }
      throw Exception(errorMessage);
    }
  }

  // ==================== Chats ====================

  Future<List<ChatInfo>> getChats(String spaceId) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.get(
      Uri.parse('$url/api/spaces/$spaceId/chats'),
      headers: ApiService.buildHeaders(baseUrl: url),
    );

    if (response.statusCode == 200) {
      List<dynamic> data = json.decode(response.body);
      return data.map((json) => ChatInfo.fromJson(json)).toList();
    } else {
      throw Exception('Failed to load chats');
    }
  }

  Future<Chat> getChat(String spaceId, String chatId) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.get(
      Uri.parse('$url/api/spaces/$spaceId/chats/$chatId'),
      headers: ApiService.buildHeaders(baseUrl: url),
    );

    if (response.statusCode == 200) {
      return Chat.fromJson(json.decode(response.body));
    } else {
      throw Exception('Failed to load chat');
    }
  }

  // Backend data management
  Future<List<int>> exportData() async {
    final response = await http.get(Uri.parse('$_baseUrl/api/system/export'));
    if (response.statusCode == 200) {
      return response.bodyBytes;
    } else {
      throw Exception('Failed to export data: ${response.statusCode}');
    }
  }

  Future<void> importData(String filePath) async {
    var request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/api/system/import'));
    request.files.add(await http.MultipartFile.fromPath('file', filePath));
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    
    if (response.statusCode != 200) {
      throw Exception('Failed to import data: ${response.body}');
    }
  }

  Future<void> importDataBytes(List<int> bytes, String filename) async {
    var request = http.MultipartRequest('POST', Uri.parse('$_baseUrl/api/system/import'));
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    
    if (response.statusCode != 200) {
      throw Exception('Failed to import data: ${response.body}');
    }
  }

  Future<void> deleteChat(String spaceId, String chatId) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.delete(
      Uri.parse('$url/api/spaces/$spaceId/chats/$chatId'),
      headers: ApiService.buildHeaders(baseUrl: url),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to delete chat');
    }
  }

  Future<void> deleteChatMessage({
    required String spaceId,
    required String chatId,
    required String timestamp,
    required String role,
    String? content,
    bool deleteRelatedUser = false,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/spaces/$spaceId/chats/$chatId/messages/delete'),
      headers: ApiService.buildHeaders(
        baseUrl: url,
        extra: {'Content-Type': 'application/json'},
      ),
      body: json.encode({
        'timestamp': timestamp,
        'role': role,
        if (content != null) 'content': content,
        'delete_related_user': deleteRelatedUser,
      }),
    );

    if (response.statusCode != 200) {
      String errorMessage = 'Failed to delete message';
      try {
        final errorData = json.decode(response.body);
        if (errorData['detail'] != null) {
          errorMessage = errorData['detail'];
        }
      } catch (_) {
        // Keep default error message
      }
      throw Exception(errorMessage);
    }
  }

  // ==================== Chat/RAG ====================

  Future<ChatResponse> sendMessage({
    required String query,
    required String spaceId,
    String? chatId,
    String workflow = 'chat',
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/chat'),
      headers: ApiService.buildHeaders(
        baseUrl: url,
        extra: {'Content-Type': 'application/json'},
      ),
      body: json.encode({
        'query': query,
        'space_id': spaceId,
        'chat_id': chatId,
        'workflow': workflow,
      }),
    );

    if (response.statusCode == 200) {
      return ChatResponse.fromJson(json.decode(response.body));
    } else {
      throw Exception(
        ApiService.formatHttpError(
          operation: 'Failed to send message',
          response: response,
        ),
      );
    }
  }

  Stream<ChatStreamEvent> sendMessageStream({
    required String query,
    required String spaceId,
    String? chatId,
    String workflow = 'chat',
  }) async* {
    final url = await ApiService.getBaseUrl();
    final request = http.Request('POST', Uri.parse('$url/api/chat/stream'));
    request.headers.addAll(
      ApiService.buildHeaders(
        baseUrl: url,
        extra: {
          'Content-Type': 'application/json',
          'Accept': 'text/event-stream',
        },
      ),
    );
    request.body = json.encode({
      'query': query,
      'space_id': spaceId,
      'chat_id': chatId,
      'workflow': workflow,
    });

    final streamed = await request.send();
    if (streamed.statusCode != 200) {
      final body = await streamed.stream.bytesToString();
      throw Exception(
        'Failed to open chat stream (HTTP ${streamed.statusCode}): $body',
      );
    }

    String currentEvent = 'message';
    await for (final line
        in streamed.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
        continue;
      }

      if (line.startsWith('data:')) {
        final raw = line.substring(5).trim();
        Map<String, dynamic> payload = {};
        try {
          payload = json.decode(raw) as Map<String, dynamic>;
        } catch (_) {
          payload = {'raw': raw};
        }
        yield ChatStreamEvent(event: currentEvent, data: payload);
      }
    }
  }

  // ==================== File Upload ====================

  Future<Map<String, dynamic>> uploadFiles(
    String spaceId,
    List<PlatformFile> files,
  ) async {
    final url = await ApiService.getBaseUrl();
    var request = http.MultipartRequest(
      'POST',
      Uri.parse('$url/api/spaces/$spaceId/upload'),
    );
    request.headers.addAll(ApiService.buildHeaders(baseUrl: url));

    for (var file in files) {
      if (file.bytes != null) {
        // Web: use bytes
        if (file.bytes!.isEmpty) {
          throw Exception('Selected file is empty: ${file.name}');
        }
        request.files.add(
          http.MultipartFile.fromBytes(
            'files',
            file.bytes!,
            filename: file.name,
          ),
        );
      } else if (file.path != null) {
        // Desktop: use path
        request.files.add(
          await http.MultipartFile.fromPath('files', file.path!),
        );
      } else {
        throw Exception('File has no bytes or path: ${file.name}');
      }
    }

    var streamedResponse = await request.send().timeout(
      const Duration(minutes: 45),
      onTimeout: () {
        throw Exception(
          'Upload timed out while waiting for backend processing.',
        );
      },
    );
    var response = await http.Response.fromStream(streamedResponse).timeout(
      const Duration(minutes: 45),
      onTimeout: () {
        throw Exception('Backend took too long to return upload response.');
      },
    );

    if (response.statusCode == 200) {
      return json.decode(response.body);
    } else {
      throw Exception(
        ApiService.formatHttpError(
          operation: 'Failed to upload files',
          response: response,
        ),
      );
    }
  }

  Future<List<Map<String, dynamic>>> getUploadedFiles(String spaceId) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.get(
      Uri.parse('$url/api/spaces/$spaceId/files'),
      headers: ApiService.buildHeaders(baseUrl: url),
    );

    if (response.statusCode == 200) {
      List<dynamic> data = json.decode(response.body);
      return data.cast<Map<String, dynamic>>();
    } else {
      throw Exception('Failed to load files');
    }
  }

  Future<void> deleteFile(String spaceId, String filename) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.delete(
      Uri.parse('$url/api/spaces/$spaceId/files/$filename'),
      headers: ApiService.buildHeaders(baseUrl: url),
    );

    if (response.statusCode != 200) {
      throw Exception(
        ApiService.formatHttpError(
          operation: 'Failed to delete file',
          response: response,
        ),
      );
    }
  }

  // ==================== Config ====================

  Future<Map<String, String?>> getConfig() async {
    final url = await ApiService.getBaseUrl();
    final response = await http.get(
      Uri.parse('$url/api/config'),
      headers: ApiService.buildHeaders(baseUrl: url),
    );

    if (response.statusCode == 200) {
      Map<String, dynamic> data = json.decode(response.body);
      return {
        'groq_api_key': data['groq_api_key'],
        'gemini_api_key': data['gemini_api_key'],
        'nvidia_api_key': data['nvidia_api_key'],
      };
    } else {
      throw Exception('Failed to load config');
    }
  }

  Future<void> updateConfig({
    String? groqKey,
    String? geminiKey,
    String? nvidiaKey,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/config'),
      headers: ApiService.buildHeaders(
        baseUrl: url,
        extra: {'Content-Type': 'application/json'},
      ),
      body: json.encode({
        if (groqKey != null) 'groq_api_key': groqKey,
        if (geminiKey != null) 'gemini_api_key': geminiKey,
        if (nvidiaKey != null) 'nvidia_api_key': nvidiaKey,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to update config');
    }
  }
}

// ==================== Models ====================

class Space {
  final String id;
  final String name;
  final String createdAt;
  final int fileCount;

  Space({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.fileCount,
  });

  factory Space.fromJson(Map<String, dynamic> json) {
    return Space(
      id: json['id'],
      name: json['name'],
      createdAt: json['created_at'],
      fileCount: json['file_count'],
    );
  }
}

class ChatInfo {
  final String id;
  final String title;
  final String preview;
  final String createdAt;
  final String updatedAt;
  final int messageCount;

  ChatInfo({
    required this.id,
    required this.title,
    required this.preview,
    required this.createdAt,
    required this.updatedAt,
    required this.messageCount,
  });

  factory ChatInfo.fromJson(Map<String, dynamic> json) {
    return ChatInfo(
      id: json['id'],
      title: json['title'],
      preview: json['preview'],
      createdAt: json['created_at'],
      updatedAt: json['updated_at'],
      messageCount: json['message_count'],
    );
  }
}

class Chat {
  final String id;
  final List<ChatMessage> messages;
  final String createdAt;
  final String updatedAt;

  Chat({
    required this.id,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Chat.fromJson(Map<String, dynamic> json) {
    return Chat(
      id: json['id'],
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(m))
          .toList(),
      createdAt: json['created_at'],
      updatedAt: json['updated_at'],
    );
  }
}

class ChatMessage {
  final String role;
  final String content;
  final String timestamp;
  final List<dynamic>? sources;
  final List<String>? suggestedFollowUps;

  ChatMessage({
    required this.role,
    required this.content,
    required this.timestamp,
    this.sources,
    this.suggestedFollowUps,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: json['role'],
      content: json['content'],
      timestamp: json['timestamp'],
      sources: json['sources'] is List
          ? List<dynamic>.from(json['sources'])
          : null,
      suggestedFollowUps: json['suggested_follow_ups'] is List
          ? List<String>.from(json['suggested_follow_ups'])
          : null,
    );
  }
}

class ChatResponse {
  final String response;
  final List<dynamic> sources;
  final String chatId;
  final String timestamp;
  final String? uiNotice;
  final List<String> suggestedFollowUps;

  ChatResponse({
    required this.response,
    required this.sources,
    required this.chatId,
    required this.timestamp,
    this.uiNotice,
    required this.suggestedFollowUps,
  });

  factory ChatResponse.fromJson(Map<String, dynamic> json) {
    return ChatResponse(
      response: json['response'],
      sources: json['sources'],
      chatId: json['chat_id'],
      timestamp: json['timestamp'],
      uiNotice: json['ui_notice'],
      suggestedFollowUps: json['suggested_follow_ups'] is List
          ? List<String>.from(json['suggested_follow_ups'])
          : <String>[],
    );
  }
}

class ChatStreamEvent {
  final String event;
  final Map<String, dynamic> data;

  ChatStreamEvent({required this.event, required this.data});
}
