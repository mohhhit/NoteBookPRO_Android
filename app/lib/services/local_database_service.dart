import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';
import '../models/studio_models.dart';

class LocalDatabaseService {
  static Database? _db;
  static const _uuid = Uuid();

  @visibleForTesting
  static void setDatabase(Database? db) {
    _db = db;
  }

  @visibleForTesting
  static Future<void> createTables(Database db) => _createTables(db);

  static Future<void> initialize() async {
    if (_db != null) return;
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'notebookpro_local.db');

    _db = await openDatabase(
      path,
      version: 3,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS files (
              id TEXT PRIMARY KEY,
              space_id TEXT NOT NULL,
              filename TEXT NOT NULL,
              virtual_filename TEXT NOT NULL,
              created_at TEXT NOT NULL,
              FOREIGN KEY (space_id) REFERENCES spaces (id) ON DELETE CASCADE
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS notebook_entries (
              id TEXT PRIMARY KEY,
              space_id TEXT NOT NULL,
              title TEXT NOT NULL,
              content TEXT NOT NULL,
              source_type TEXT DEFAULT 'manual',
              source_id TEXT,
              tags TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              metadata TEXT,
              FOREIGN KEY (space_id) REFERENCES spaces (id) ON DELETE CASCADE
            )
          ''');
        }
      },
    );

    // Bullet-proof fallback for prototypes
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS files (
        id TEXT PRIMARY KEY,
        space_id TEXT NOT NULL,
        filename TEXT NOT NULL,
        virtual_filename TEXT NOT NULL,
        created_at TEXT NOT NULL,
        FOREIGN KEY (space_id) REFERENCES spaces (id) ON DELETE CASCADE
      )
    ''');
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS notebook_entries (
        id TEXT PRIMARY KEY,
        space_id TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        source_type TEXT DEFAULT 'manual',
        source_id TEXT,
        tags TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        metadata TEXT,
        FOREIGN KEY (space_id) REFERENCES spaces (id) ON DELETE CASCADE
      )
    ''');
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE spaces (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            file_count INTEGER DEFAULT 0,
            chat_count INTEGER DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE chats (
            id TEXT PRIMARY KEY,
            space_id TEXT NOT NULL,
            title TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            FOREIGN KEY (space_id) REFERENCES spaces (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            chat_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            citations TEXT,
            FOREIGN KEY (chat_id) REFERENCES chats (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE files (
            id TEXT PRIMARY KEY,
            space_id TEXT NOT NULL,
            filename TEXT NOT NULL,
            virtual_filename TEXT NOT NULL,
            created_at TEXT NOT NULL,
            FOREIGN KEY (space_id) REFERENCES spaces (id) ON DELETE CASCADE
          )
        ''');

        await db.execute('''
          CREATE TABLE notebook_entries (
            id TEXT PRIMARY KEY,
            space_id TEXT NOT NULL,
            title TEXT NOT NULL,
            content TEXT NOT NULL,
            source_type TEXT DEFAULT 'manual',
            source_id TEXT,
            tags TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            metadata TEXT,
            FOREIGN KEY (space_id) REFERENCES spaces (id) ON DELETE CASCADE
          )
        ''');
  }

  // --- Files ---
  static Future<List<Map<String, dynamic>>> getFiles(String spaceId) async {
    return await _db!.query('files', where: 'space_id = ?', whereArgs: [spaceId], orderBy: 'created_at DESC');
  }

  static Future<void> addFile(String spaceId, String filename, String virtualFilename) async {
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    await _db!.insert('files', {
      'id': id,
      'space_id': spaceId,
      'filename': filename,
      'virtual_filename': virtualFilename,
      'created_at': now,
    });
    
    // Increment file count
    await _db!.rawUpdate('UPDATE spaces SET file_count = file_count + 1 WHERE id = ?', [spaceId]);
  }

  static Future<void> deleteFile(String spaceId, String filename) async {
    final count = await _db!.delete('files', where: 'space_id = ? AND filename = ?', whereArgs: [spaceId, filename]);
    if (count > 0) {
      await _db!.rawUpdate('UPDATE spaces SET file_count = file_count - 1 WHERE id = ?', [spaceId]);
    }
  }

  // --- Spaces ---
  static Future<Map<String, dynamic>> createSpace(String name) async {
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final data = {
      'id': id,
      'name': name,
      'file_count': 0,
      'chat_count': 0,
      'created_at': now,
    };
    await _db!.insert('spaces', data);
    return data;
  }

  static Future<List<Map<String, dynamic>>> getSpaces() async {
    return await _db!.query('spaces', orderBy: 'created_at DESC');
  }

  static Future<void> deleteSpace(String spaceId) async {
    await _db!.delete('spaces', where: 'id = ?', whereArgs: [spaceId]);
  }

  // --- Chats ---
  static Future<List<Map<String, dynamic>>> getChats(String spaceId) async {
    return await _db!.query('chats',
        where: 'space_id = ?',
        whereArgs: [spaceId],
        orderBy: 'updated_at DESC');
  }

  static Future<Map<String, dynamic>> createChat(String spaceId, String title) async {
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final data = {
      'id': id,
      'space_id': spaceId,
      'title': title,
      'updated_at': now,
    };
    await _db!.insert('chats', data);
    return data;
  }

  static Future<void> deleteChat(String chatId) async {
    await _db!.delete('chats', where: 'id = ?', whereArgs: [chatId]);
  }

  static Future<Map<String, dynamic>> getChatWithMessages(String chatId) async {
    final chatRows = await _db!.query('chats', where: 'id = ?', whereArgs: [chatId]);
    if (chatRows.isEmpty) throw Exception('Chat not found');
    final chat = Map<String, dynamic>.from(chatRows.first);

    final messages = await _db!.query('messages',
        where: 'chat_id = ?', whereArgs: [chatId], orderBy: 'timestamp ASC');
    
    chat['messages'] = messages;
    return chat;
  }

  // --- Messages ---
  static Future<void> addMessage(String chatId, String role, String content) async {
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    await _db!.insert('messages', {
      'id': id,
      'chat_id': chatId,
      'role': role,
      'content': content,
      'timestamp': now,
    });
    await _db!.update('chats', {'updated_at': now},
        where: 'id = ?', whereArgs: [chatId]);
  }

  // --- Notebook Entries ---
  static NotebookEntry _entryFromRow(Map<String, dynamic> row) {
    List<String> tags = [];
    if (row['tags'] != null && row['tags'].toString().isNotEmpty) {
      try {
        final decoded = jsonDecode(row['tags']);
        if (decoded is List) {
          tags = decoded.map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }

    Map<String, dynamic> metadata = {};
    if (row['metadata'] != null && row['metadata'].toString().isNotEmpty) {
      try {
        final decoded = jsonDecode(row['metadata']);
        if (decoded is Map<String, dynamic>) {
          metadata = decoded;
        }
      } catch (_) {}
    }

    return NotebookEntry(
      id: row['id'],
      spaceId: row['space_id'],
      title: row['title'] ?? '',
      content: row['content'] ?? '',
      sourceType: row['source_type'] ?? 'manual',
      sourceId: row['source_id'],
      tags: tags,
      createdAt: DateTime.tryParse(row['created_at'] ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(row['updated_at'] ?? '') ?? DateTime.now(),
      metadata: metadata,
    );
  }

  static Future<NotebookEntry> createNotebookEntry({
    required String spaceId,
    required String title,
    required String content,
    String sourceType = 'manual',
    String? sourceId,
    List<String>? tags,
    Map<String, dynamic>? metadata,
  }) async {
    final id = _uuid.v4();
    final now = DateTime.now().toIso8601String();
    final entry = NotebookEntry(
      id: id,
      spaceId: spaceId,
      title: title,
      content: content,
      sourceType: sourceType,
      sourceId: sourceId,
      tags: tags ?? [],
      createdAt: DateTime.parse(now),
      updatedAt: DateTime.parse(now),
      metadata: metadata ?? {},
    );

    await _db!.insert('notebook_entries', {
      'id': id,
      'space_id': spaceId,
      'title': title,
      'content': content,
      'source_type': sourceType,
      'source_id': sourceId,
      'tags': jsonEncode(tags ?? []),
      'created_at': now,
      'updated_at': now,
      'metadata': jsonEncode(metadata ?? {}),
    });

    return entry;
  }

  static Future<List<NotebookEntry>> getNotebookEntries({String? spaceId}) async {
    final List<Map<String, dynamic>> rows;
    if (spaceId != null) {
      rows = await _db!.query(
        'notebook_entries',
        where: 'space_id = ?',
        whereArgs: [spaceId],
        orderBy: 'updated_at DESC',
      );
    } else {
      rows = await _db!.query(
        'notebook_entries',
        orderBy: 'updated_at DESC',
      );
    }
    return rows.map(_entryFromRow).toList();
  }

  static Future<NotebookEntry?> getNotebookEntry(String entryId) async {
    final rows = await _db!.query(
      'notebook_entries',
      where: 'id = ?',
      whereArgs: [entryId],
    );
    if (rows.isEmpty) return null;
    return _entryFromRow(rows.first);
  }

  static Future<NotebookEntry> updateNotebookEntry(
    String entryId, {
    String? title,
    String? content,
    List<String>? tags,
    Map<String, dynamic>? metadata,
  }) async {
    final existing = await getNotebookEntry(entryId);
    if (existing == null) throw Exception('Notebook entry not found: $entryId');

    final now = DateTime.now().toIso8601String();
    final updatedValues = <String, dynamic>{
      'updated_at': now,
    };
    if (title != null) updatedValues['title'] = title;
    if (content != null) updatedValues['content'] = content;
    if (tags != null) updatedValues['tags'] = jsonEncode(tags);
    if (metadata != null) updatedValues['metadata'] = jsonEncode(metadata);

    await _db!.update(
      'notebook_entries',
      updatedValues,
      where: 'id = ?',
      whereArgs: [entryId],
    );

    return NotebookEntry(
      id: existing.id,
      spaceId: existing.spaceId,
      title: title ?? existing.title,
      content: content ?? existing.content,
      sourceType: existing.sourceType,
      sourceId: existing.sourceId,
      tags: tags ?? existing.tags,
      createdAt: existing.createdAt,
      updatedAt: DateTime.parse(now),
      metadata: metadata ?? existing.metadata,
    );
  }

  static Future<void> deleteNotebookEntry(String entryId) async {
    await _db!.delete(
      'notebook_entries',
      where: 'id = ?',
      whereArgs: [entryId],
    );
  }
}
