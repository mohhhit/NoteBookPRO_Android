import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class VectorDbService {
  static Database? _db;
  static final _uuid = const Uuid();

  static Future<void> initialize() async {
    if (_db != null) return;
    
    final docDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docDir.path, 'notebook_fts.db'); 

    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE VIRTUAL TABLE document_chunks USING fts4(
            id,
            space_id,
            text_content,
            metadata
          )
        ''');
      },
    );
  }

  static Future<void> addDocuments(String spaceId, List<String> texts, List<Map<String, dynamic>> metadatas, {Function(int, int)? onProgress}) async {
    if (_db == null) throw Exception('DB not initialized');
    if (texts.isEmpty) return;

    var dbBatch = _db!.batch();

    for (int i = 0; i < texts.length; i++) {
      if (onProgress != null && i % 100 == 0) onProgress(i + 1, texts.length);
      
      final id = _uuid.v4();

      dbBatch.insert('document_chunks', {
        'id': id,
        'space_id': spaceId,
        'text_content': texts[i],
        'metadata': jsonEncode(metadatas[i]),
      });

      if ((i + 1) % 500 == 0) {
        await dbBatch.commit(noResult: true);
        dbBatch = _db!.batch();
      }
    }
    
    await dbBatch.commit(noResult: true);
    if (onProgress != null) onProgress(texts.length, texts.length);
  }

  static Future<List<Map<String, dynamic>>> query(String spaceId, String queryText, {int nResults = 5}) async {
    if (_db == null) throw Exception('DB not initialized');
    
    final cleanQuery = queryText.replaceAll(RegExp(r'[^\w\s]'), ' ').trim().split(RegExp(r'\s+')).join(' OR ');
    
    if (cleanQuery.isEmpty) return [];

    try {
      final List<Map<String, dynamic>> rows = await _db!.rawQuery('''
        SELECT text_content, metadata
        FROM document_chunks 
        WHERE space_id = ? AND document_chunks MATCH ? 
        LIMIT ?
      ''', [spaceId, cleanQuery, nResults]);

      return rows.map((row) => {
        'content': row['text_content'],
        'metadata': jsonDecode(row['metadata'] as String),
        'score': 1.0,
      }).toList();
    } catch (e) {
      print('FTS Query error: $e');
      return [];
    }
  }

  static Future<void> deleteDocumentsByFilename(String spaceId, String filename) async {
    if (_db == null) throw Exception('DB not initialized');
    
    await _db!.delete(
      'document_chunks',
      where: 'space_id = ? AND metadata LIKE ?',
      whereArgs: [spaceId, '%"filename":"$filename"%'],
    );
  }
  
  static Future<int> getFileChunkCount(String spaceId, String virtualFilename) async {
    if (_db == null) return 0;
    
    final result = await _db!.rawQuery(
      "SELECT COUNT(*) FROM document_chunks WHERE space_id = ? AND metadata LIKE ?",
      [spaceId, '%"virtual_filename":"$virtualFilename"%']
    );
    
    if (result.isNotEmpty) {
      return result.first.values.first as int? ?? 0;
    }
    return 0;
  }
}
