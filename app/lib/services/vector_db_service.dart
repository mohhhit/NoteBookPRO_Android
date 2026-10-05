import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:llamadart/llamadart.dart';
import 'package:uuid/uuid.dart';

class VectorDbService {
  static Database? _db;
  static LlamaEngine? _embedEngine;
  static final _uuid = const Uuid();

  static Future<void> initialize() async {
    if (_db != null) return;
    
    final docDir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docDir.path, 'notebook_vectors.db');

    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE document_chunks (
            id TEXT PRIMARY KEY,
            space_id TEXT NOT NULL,
            text_content TEXT NOT NULL,
            embedding BLOB NOT NULL,
            metadata TEXT NOT NULL
          )
        ''');
      },
    );

    // Initialize the embedding model
    final embedPath = '${docDir.path}/all-MiniLM-L6-v2-ggml-model-f16.gguf';
    final embedFile = File(embedPath);
    if (!await embedFile.exists()) {
      print('Embedding model not downloaded yet.');
      return;
    }
    
    final backend = LlamaBackend();
    _embedEngine = LlamaEngine(backend);
    await _embedEngine!.loadModel(
      embedPath,
      modelParams: const ModelParams(
        contextSize: 1024,
      ),
    );
  }

  static Future<void> addDocuments(String spaceId, List<String> texts, List<Map<String, dynamic>> metadatas, {Function(int, int)? onProgress}) async {
    if (_embedEngine == null) throw Exception('Embed engine not initialized');
    if (texts.isEmpty) return;

    for (int i = 0; i < texts.length; i++) {
      if (onProgress != null) onProgress(i + 1, texts.length);
      // Yield to event loop to prevent UI freezes / ANRs
      await Future.delayed(const Duration(milliseconds: 1));
      
      // Process one by one to prevent Vulkan OOM
      final emb = await _embedEngine!.embed(texts[i], normalize: true);
      
      final id = _uuid.v4();
      final floatList = Float32List.fromList(emb);
      final blob = floatList.buffer.asUint8List();

      await _db!.insert('document_chunks', {
        'id': id,
        'space_id': spaceId,
        'text_content': texts[i],
        'embedding': blob,
        'metadata': jsonEncode(metadatas[i]),
      });
    }
  }

  static Future<List<Map<String, dynamic>>> query(String spaceId, String queryText, {int nResults = 5}) async {
    if (_embedEngine == null) throw Exception('Embed engine not initialized');
    if (_db == null) throw Exception('DB not initialized');

    final instruction = "Given a student's question, retrieve relevant passages from academic textbooks that answer the question\nQuery: $queryText";
    final queryEmbedding = await _embedEngine!.embed(instruction, normalize: true);

    final List<Map<String, dynamic>> rows = await _db!.query(
      'document_chunks',
      where: 'space_id = ?',
      whereArgs: [spaceId],
    );

    if (rows.isEmpty) return [];

    final scoredChunks = <_ScoredChunk>[];

    for (final row in rows) {
      final blob = row['embedding'] as Uint8List;
      final floatList = blob.buffer.asFloat32List(blob.offsetInBytes, blob.lengthInBytes ~/ 4);
      final sim = _cosineSimilarity(queryEmbedding, floatList);
      
      scoredChunks.add(_ScoredChunk(
        score: sim,
        textContent: row['text_content'] as String,
        metadata: jsonDecode(row['metadata'] as String),
      ));
    }

    scoredChunks.sort((a, b) => b.score.compareTo(a.score));

    return scoredChunks.take(nResults).map((e) => {
      'content': e.textContent,
      'metadata': e.metadata,
      'score': e.score,
    }).toList();
  }

  static Future<void> deleteDocumentsByFilename(String spaceId, String filename) async {
    if (_db == null) throw Exception('DB not initialized');
    
    // Extract metadata using JSON path or LIKE since it's stored as JSON string.
    // For simplicity, we can just delete where metadata contains the filename.
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

  static double _cosineSimilarity(List<double> a, Float32List b) {
    if (a.length != b.length) return 0.0;
    double dot = 0.0;
    for (int i = 0; i < a.length; i++) {
      dot += a[i] * b[i]; // Vectors are pre-normalized, so dot product == cosine sim
    }
    return dot;
  }
}

class _ScoredChunk {
  final double score;
  final String textContent;
  final Map<String, dynamic> metadata;

  _ScoredChunk({required this.score, required this.textContent, required this.metadata});
}
