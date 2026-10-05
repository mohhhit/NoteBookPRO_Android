import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';

class LocalDatabaseService {
  static Database? _db;
  static const _uuid = Uuid();

  static Future<void> initialize() async {
    if (_db != null) return;
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'notebookpro_local.db');

    _db = await openDatabase(
      path,
      version: 2,
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
}
