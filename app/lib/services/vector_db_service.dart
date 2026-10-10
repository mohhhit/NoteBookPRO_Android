import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class VectorDbService {
  static Database? _db;
  static final _uuid = const Uuid();

  static Future<void> initialize() async {
    if (_db != null) return;
    
    // Use the bundled sqlite3 libs that support FTS5
    if (Platform.isAndroid || Platform.isIOS || Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    
    final docDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docDir.path, 'notebook_fts5.db'); // Changed to new db file to avoid migration issues

    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE VIRTUAL TABLE document_chunks USING fts5(
            id UNINDEXED,
            space_id UNINDEXED,
            text_content,
            metadata UNINDEXED,
            tokenize = 'porter'
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

  // --- MMR Helpers ---

  static double _jaccard(String a, String b) {
    final setA = a.toLowerCase().split(RegExp(r'\s+')).toSet();
    final setB = b.toLowerCase().split(RegExp(r'\s+')).toSet();
    if (setA.isEmpty && setB.isEmpty) return 1.0;
    final intersection = setA.intersection(setB).length;
    final union = setA.union(setB).length;
    return union == 0 ? 0.0 : intersection / union;
  }

  static List<Map<String, dynamic>> _mmrSelect(
    List<Map<String, dynamic>> candidates,
    int nResults,
  ) {
    if (candidates.isEmpty) return [];

    final selected = <Map<String, dynamic>>[];
    final sectionCount = <String, int>{};
    final bookCount = <String, int>{};

    final bestBm25 = -(candidates.first['score'] as num).toDouble();
    final relevanceFloor = (bestBm25 * 0.25).clamp(1.5, double.infinity);
    print('RAG: Best BM25 = $bestBm25, Relevance Floor = $relevanceFloor');

    final validCandidates = candidates.where((c) {
      final bm25 = -(c['score'] as num).toDouble();
      if (bm25 < relevanceFloor) return false;
      
      final content = (c['content'] as String).toLowerCase();
      int proceduralScore = 0;
      if (content.contains('run the following command')) proceduralScore += 2;
      if (content.contains('apt-get install') || content.contains('yum install') || content.contains('snap install') || content.contains('brew install')) proceduralScore += 2;
      if (RegExp(r'\$\s+[a-z]').allMatches(content).length >= 2) proceduralScore += 2;
      if (content.contains('docker desktop')) proceduralScore += 2;
      
      if (proceduralScore >= 2) return false;
      return true;
    }).toList();

    while (selected.length < nResults && validCandidates.isNotEmpty) {
      Map<String, dynamic>? best;
      double bestScore = double.negativeInfinity;
      double bestCandidateBm25 = 0;

      for (final candidate in validCandidates) {
        final meta = candidate['metadata'] as Map<String, dynamic>;
        final book = (meta['virtual_filename'] ?? 'unknown') as String;
        final chunkIdx = (meta['chunk_index'] ?? 0) as int;
        final sectionKey = '${book}_${chunkIdx ~/ 5}';

        if ((sectionCount[sectionKey] ?? 0) >= 2) continue;
        if ((bookCount[book] ?? 0) >= 3) continue;

        final bm25 = -(candidate['score'] as num).toDouble();
        double maxSim = 0.0;
        for (final sel in selected) {
          final sim = _jaccard(
            candidate['content'] as String,
            sel['content'] as String,
          );
          if (sim > maxSim) maxSim = sim;
        }

        const lambda = 0.7;
        final mmr = lambda * bm25 - (1 - lambda) * maxSim;

        if (mmr > bestScore) {
          bestScore = mmr;
          best = candidate;
          bestCandidateBm25 = bm25;
        }
      }

      if (best == null) break;

      print('RAG: Selected chunk from ${best['metadata']['virtual_filename']} (pos: ${selected.length + 1}) with BM25: ${bestCandidateBm25.toStringAsFixed(2)}, MMR: ${bestScore.toStringAsFixed(2)}');
      selected.add(best);
      validCandidates.remove(best);

      final meta = best['metadata'] as Map<String, dynamic>;
      final book = (meta['virtual_filename'] ?? 'unknown') as String;
      final chunkIdx = (meta['chunk_index'] ?? 0) as int;
      final sectionKey = '${book}_${chunkIdx ~/ 5}';
      sectionCount[sectionKey] = (sectionCount[sectionKey] ?? 0) + 1;
      bookCount[book] = (bookCount[book] ?? 0) + 1;
    }

    return selected;
  }

  static Future<List<Map<String, dynamic>>> query(
    String spaceId, 
    String queryText, {
    int nResults = 5,
    int candidatePool = 40,
  }) async {
    if (_db == null) throw Exception('DB not initialized');
    
    final cleanQuery = queryText.replaceAll(RegExp(r'[^\w\s]'), ' ').trim().split(RegExp(r'\s+')).join(' OR ');
    
    if (cleanQuery.isEmpty) return [];

    try {
      final List<Map<String, dynamic>> rows = await _db!.rawQuery('''
        SELECT text_content, metadata, bm25(document_chunks) as score
        FROM document_chunks 
        WHERE space_id = ? AND document_chunks MATCH ? 
        ORDER BY score ASC
        LIMIT ?
      ''', [spaceId, cleanQuery, candidatePool]);

      final candidates = rows.map((row) => {
        'content': row['text_content'],
        'metadata': jsonDecode(row['metadata'] as String),
        'score': row['score'],
      }).toList();

      return _mmrSelect(candidates, nResults);
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
