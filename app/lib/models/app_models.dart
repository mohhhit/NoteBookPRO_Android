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
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      createdAt: json['created_at'] ?? '',
      fileCount: json['file_count'] ?? 0,
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
      id: json['id'] ?? '',
      title: json['title'] ?? '',
      preview: json['preview'] ?? '',
      createdAt: json['created_at'] ?? '',
      updatedAt: json['updated_at'] ?? '',
      messageCount: json['message_count'] ?? 0,
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
      id: json['id'] ?? '',
      messages: (json['messages'] as List?)
          ?.map((m) => ChatMessage.fromJson(m))
          .toList() ?? [],
      createdAt: json['created_at'] ?? '',
      updatedAt: json['updated_at'] ?? '',
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
      role: json['role'] ?? '',
      content: json['content'] ?? '',
      timestamp: json['timestamp'] ?? '',
      sources: json['sources'] is List
          ? List<dynamic>.from(json['sources'])
          : null,
      suggestedFollowUps: json['suggested_follow_ups'] is List
          ? List<String>.from(json['suggested_follow_ups'])
          : null,
    );
  }
}
