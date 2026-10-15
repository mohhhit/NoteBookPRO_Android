import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
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

  /// Returns the number of indexed chunks for a given space.
  static Future<int> getChunkCount(String spaceId) async {
    if (_db == null) return 0;
    try {
      final res = await _db!.rawQuery(
        'SELECT count(*) as count FROM document_chunks WHERE space_id = ?',
        [spaceId],
      );
      if (res.isNotEmpty) {
        return (res.first['count'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
    return 0;
  }

  /// Returns total indexed chunks across all spaces.
  static Future<int> getTotalChunkCount() async {
    if (_db == null) return 0;
    try {
      final res = await _db!.rawQuery('SELECT count(*) as count FROM document_chunks');
      if (res.isNotEmpty) {
        return (res.first['count'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {}
    return 0;
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

    final validCandidates = List<Map<String, dynamic>>.from(candidates);
    final maxPerBook = (nResults * 0.65).ceil().clamp(3, nResults);

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
        if ((bookCount[book] ?? 0) >= maxPerBook) continue;

        final bm25 = -(candidate['score'] as num).toDouble();
        double maxSim = 0.0;
        for (final sel in selected) {
          final sim = _jaccard(
            candidate['content'] as String,
            sel['content'] as String,
          );
          if (sim > maxSim) maxSim = sim;
        }

        const lambda = 0.6;
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

  static bool isConceptualQuery(String query) {
    final lower = query.toLowerCase().trim();
    final isProcedural = lower.startsWith('how do i') ||
        lower.startsWith('how can i') ||
        lower.startsWith('how to') ||
        lower.contains('what command') ||
        lower.contains('which command') ||
        lower.contains('syntax for') ||
        lower.contains('command for') ||
        lower.contains('steps to') ||
        lower.contains('how do we run');
    return !isProcedural;
  }

  static bool _isChunkTechnicalNoise(String text) {
    // 1. Strip the chunk metadata header ('Source Document: ...\n---\n' and '[Section: ...]')
    // so headers and horizontal rules are NEVER misclassified as noise!
    var body = text;
    if (body.startsWith('Source Document:')) {
      final sepIdx = body.indexOf('\n---\n');
      if (sepIdx != -1) {
        body = body.substring(sepIdx + 5).trim();
      }
    }
    if (body.startsWith('[Section:') && body.contains(']\n')) {
      final closeIdx = body.indexOf(']\n');
      if (closeIdx != -1) {
        body = body.substring(closeIdx + 2).trim();
      }
    }

    final lines = body.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return true;

    // Fast-pass: If the body contains substantial English prose (e.g. >= 35 letters with good character density),
    // and is not a raw terminal command script, it is legitimate explanatory content!
    final letters = RegExp(r'[A-Za-z]').allMatches(body).length;
    final digits = RegExp(r'\d').allMatches(body).length;
    if (letters < 35) return true;
    if (digits > 0 && letters < math.max(60, (digits * 0.35).toInt())) return true;

    int noiseLineCount = 0;
    int commandCount = 0;
    int treeLineCount = 0;
    int diagramCount = 0;
    int tocLineCount = 0;
    int hashCount = 0;

    final cliCommandPattern = RegExp(
      r'^(?:docker|sudo|curl|kubectl|git|apt-get|yum|npm|pip|yarn|systemctl|export|cd|mkdir|cat|chmod|chown)\b', 
      caseSensitive: false,
    );
    final promptPattern = RegExp(r'^[\$#>]\s+[a-z0-9_-]', caseSensitive: false);
    final pathPattern = RegExp(r'^(?:\/|[a-zA-Z]:\\|\.\/|\.\.\/)');
    final treePattern = RegExp(r'[├──└──│\+\|]');
    final tableHashPattern = RegExp(r'\b[0-9a-f]{12,64}\b');
    final diagramArrowPattern = RegExp(r'(-->|<--|==>|<==|──>|<──)');
    final diagramBoxPattern = RegExp(r'(\+[-=]+\+|\+[-=]+|\|[-=]+\|)');
    final tocTrailPattern = RegExp(r'(?:\.{3,})\s*\d+\s*$', caseSensitive: false);
    final hashBlockPattern = RegExp(r'\b(?:sha256:)?[0-9a-f]{32,64}\b', caseSensitive: false);

    for (final line in lines) {
      bool isNoiseLine = false;
      if (promptPattern.hasMatch(line) || cliCommandPattern.hasMatch(line)) {
        isNoiseLine = true;
        commandCount++;
      } else if (pathPattern.hasMatch(line)) {
        isNoiseLine = true;
      } else if (treePattern.hasMatch(line) && (line.contains('├──') || line.contains('└──') || line.contains('│   '))) {
        isNoiseLine = true;
        treeLineCount++;
      } else if (diagramArrowPattern.hasMatch(line) || diagramBoxPattern.hasMatch(line)) {
        isNoiseLine = true;
        diagramCount++;
      } else if (tocTrailPattern.hasMatch(line)) {
        isNoiseLine = true;
        tocLineCount++;
      } else if (line.contains('CONTAINER ID') || line.contains('IMAGE ID') || line.contains('REPOSITORY   TAG')) {
        isNoiseLine = true;
      } else if (tableHashPattern.hasMatch(line) && (line.contains('Up ') || line.contains('Exited ') || line.contains('seconds ago') || line.contains('minutes ago'))) {
        isNoiseLine = true;
      }

      if (hashBlockPattern.hasMatch(line)) {
        hashCount++;
      }

      if (isNoiseLine) {
        noiseLineCount++;
      }
    }

    // 1. If 3 or more distinct CLI command lines are present (installer scripts)
    if (commandCount >= 3) return true;

    // 2. If 3 or more directory tree lines are present
    if (treeLineCount >= 3) return true;

    // 3. If diagram drawings or pipeline box dumps dominate (>= 3)
    if (diagramCount >= 3) return true;

    // 4. If table of contents dotted page number trails are present (>= 3)
    if (tocTrailPattern.hasMatch(body) && tocLineCount >= 3) return true;

    // 5. If 3 or more sha256 / hex hashes are present without sufficient prose
    if (hashCount >= 3) return true;

    // 6. If noise lines make up >= 50% of total lines in a script dump
    if (lines.length >= 4 && (noiseLineCount / lines.length) >= 0.50) return true;

    return false;
  }

  /// Detects index-like catalog chunks (e.g. "reputational risk, 64 ... Jenkins build system, 76 ...").
  /// Characterized by repeated comma-separated page numbers or high number token density.
  static bool _isIndexLikeChunk(String text) {
    if (text.length < 80) return false;
    // Pattern A: Repeated comma-separated page numbers: e.g. "term, 76" or "term, 28, 78"
    final commaPageMatches = RegExp(r',\s*\d{1,4}\b').allMatches(text).length;
    if (commaPageMatches >= 4) return true;

    // Pattern B: High density of short number tokens: >= 8 per 400 chars
    final shortNumbers = RegExp(r'\b\d{1,3}\b').allMatches(text).length;
    final expectedBlocksOf400 = text.length / 400.0;
    if (expectedBlocksOf400 > 0 && (shortNumbers / expectedBlocksOf400) >= 8.0) {
      return true;
    }

    return false;
  }

  /// Detects author / person / citation false positives (e.g. "Box and G. M. Jenkins (1970)", "Box-Jenkins").
  /// If every occurrence of the core entity is tied to a person's name or academic citation, drop it.
  static bool _isPersonOrCitationFalsePositive(String text, String? entityAnchor) {
    if (entityAnchor == null || entityAnchor.trim().isEmpty) return false;
    final entity = entityAnchor.trim().toLowerCase();
    if (entity.length < 3) return false;

    final entityRegex = RegExp(r'\b' + RegExp.escape(entity) + r'\b', caseSensitive: false);
    final totalMatches = entityRegex.allMatches(text).length;
    if (totalMatches == 0) return false;

    // Matches initials + entity, hyphenated/dashed author names, author lists, or citation year parentheses
    final personRegex = RegExp(
      r'(?:[A-Z]\.\s*(?:[A-Z]\.\s*)?' + RegExp.escape(entity) + r'\b)|' +
      r'(?:\b[A-Za-z]+[-–—]' + RegExp.escape(entity) + r'\b)|' +
      r'(?:\b' + RegExp.escape(entity) + r'[-–—][A-Za-z]+\b)|' +
      r'(?:\b[A-Z][a-z]+\s+(?:and|&)\s+(?:[A-Z]\.\s*)*' + RegExp.escape(entity) + r'\b)|' +
      r'(?:\b' + RegExp.escape(entity) + r'\s*\([^)]*(?:19\d\d|20\d\d)[^)]*\))|' +
      r'(?:\([^\)]*\b' + RegExp.escape(entity) + r'\b[^\)]*(?:19\d\d|20\d\d)[^\)]*\))',
      caseSensitive: false,
    );

    // Special check for Jenkins: if text is about Box-Jenkins forecasting / time series
    // and lacks CI/CD terminology, reject it immediately
    if (entity == 'jenkins') {
      final textLower = text.toLowerCase();
      final hasBoxJenkins = textLower.contains('box-jenkins') ||
          textLower.contains('box–jenkins') ||
          textLower.contains('box and jenkins') ||
          textLower.contains('g. m. jenkins') ||
          textLower.contains('g.e.p. box');
      final hasCiCd = textLower.contains('ci') ||
          textLower.contains('pipeline') ||
          textLower.contains('build') ||
          textLower.contains('deploy') ||
          textLower.contains('continuous integration') ||
          textLower.contains('automation server');
      if (hasBoxJenkins && !hasCiCd) {
        return true;
      }
    }

    final personMatches = personRegex.allMatches(text).length;
    if (personMatches > 0 && personMatches >= totalMatches) {
      return true;
    }

    return false;
  }

  @visibleForTesting
  static bool isIndexLikeChunk(String text) => _isIndexLikeChunk(text);

  @visibleForTesting
  static bool isPersonOrCitationFalsePositive(String text, String? entityAnchor) =>
      _isPersonOrCitationFalsePositive(text, entityAnchor);

  @visibleForTesting
  static bool isChunkTechnicalNoise(String text) => _isChunkTechnicalNoise(text);

  static List<Map<String, dynamic>> _filterNoiseCandidates(
    List<Map<String, dynamic>> candidates, {
    String queryText = '',
    String? entityAnchor,
  }) {
    if (candidates.isEmpty) return [];

    final isConceptual = isConceptualQuery(queryText);

    return candidates.where((c) {
      final rawContent = c['content'] as String;
      final content = rawContent.toLowerCase();

      // Filter out Table of Contents, Index, and Front Matter
      if (content.contains('table of contents') || content.contains('contents at a glance')) return false;
      if (RegExp(r'^\s*chapter\s+\d+[:\s].*\n\s*chapter\s+\d+[:\s]', multiLine: true).hasMatch(content)) return false;
      if (RegExp(r'\.{3,}\s*\d+').allMatches(content).length >= 2) return false;
      if (content.contains('index') && RegExp(r'\b\d{2,3},\s*\d{2,3}\b').hasMatch(content)) return false;
      if (content.contains('all rights reserved') && content.contains('isbn')) return false;
      if (RegExp(r'covered in chapter \d+|discussed in chapter \d+|detail in chapter \d+').hasMatch(content) && content.length < 350) return false;

      // Filter out Index page catalogs
      if (_isIndexLikeChunk(rawContent)) return false;

      // Filter out Person / Citation false positives (e.g. Box-Jenkins)
      if (_isPersonOrCitationFalsePositive(rawContent, entityAnchor)) return false;

      // Filter out commands, trees, hashes, or directory outputs for conceptual questions
      if (isConceptual && _isChunkTechnicalNoise(rawContent)) {
        return false;
      }

      int proceduralScore = 0;
      if (content.contains('run the following command') || content.contains('run this command')) proceduralScore += 2;
      if (content.contains('apt-get install') || content.contains('yum install') || content.contains('snap install') || content.contains('brew install')) proceduralScore += 3;
      if (content.contains('sudo apt') || content.contains('sudo yum') || content.contains('sudo dnf') || content.contains('sudo systemctl')) proceduralScore += 3;
      if (content.contains('curl ') && (content.contains('| sh') || content.contains('| bash') || content.contains('-fssl') || content.contains('get.docker.com'))) proceduralScore += 3;
      if (content.contains('docker run hello-world') || content.contains('docker run -d hello-world')) proceduralScore += 2;
      if (content.contains('installation guide') || content.contains('download and install') || content.contains('how to install')) proceduralScore += 2;

      // Only reject if it's heavily procedural / raw installer script (score >= 4)
      if (proceduralScore >= 4) return false;
      return true;
    }).toList();
  }

  static Future<List<Map<String, dynamic>>> getBm25Candidates(
    String spaceId, 
    String queryText, {
    int candidatePool = 35,
    String? entityAnchor,
  }) async {
    if (_db == null) throw Exception('DB not initialized');
    
    const stopWords = {
      'how', 'does', 'do', 'did', 'is', 'are', 'was', 'were', 'what', 'why',
      'when', 'where', 'which', 'who', 'the', 'a', 'an', 'in', 'on', 'at',
      'to', 'for', 'of', 'with', 'by', 'and', 'or', 'about', 'can', 'could',
      'would', 'should', 'work', 'works', 'working', 'explain', 'tell', 'me'
    };
    const typoCorrections = {
      'accomodate': 'accommodate',
      'accomodates': 'accommodates',
      'accomodated': 'accommodated',
      'accomodating': 'accommodating',
      'seperate': 'separate',
      'seperated': 'separated',
      'seperates': 'separates',
      'seperating': 'separating',
      'postgress': 'postgres',
      'refered': 'referred',
      'occured': 'occurred',
      'unstructred': 'unstructured',
      'warehous': 'warehouse',
      'warehouss': 'warehouses',
      'architechture': 'architecture',
      'architechtures': 'architectures',
      'infrastucture': 'infrastructure',
    };
    final words = queryText
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .trim()
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 1)
        .map((w) => typoCorrections[w] ?? w)
        .toList();
    final contentWords = words.where((w) => !stopWords.contains(w)).toList();
    final queryTerms = contentWords.isNotEmpty ? contentWords : words;
    if (queryTerms.isEmpty) return [];

    try {
      final seenTexts = <String>{};
      final rows = <Map<String, dynamic>>[];

      void addUniqueRows(List<Map<String, dynamic>> newRows) {
        for (final r in newRows) {
          final txt = r['text_content'] as String? ?? '';
          if (txt.isNotEmpty && !seenTexts.contains(txt)) {
            seenTexts.add(txt);
            rows.add(r);
          }
        }
      }

      // If an entity anchor is provided or the query starts with an entity word:
      final anchor = entityAnchor?.trim().toLowerCase();
      final effectiveAnchor = (anchor != null && anchor.isNotEmpty) 
          ? anchor 
          : (queryTerms.length > 1 ? queryTerms.first : null);

      if (effectiveAnchor != null && effectiveAnchor.length > 2) {
        final anchorWords = effectiveAnchor
            .replaceAll(RegExp(r'[^\w\-]'), ' ')
            .trim()
            .split(RegExp(r'\s+'))
            .where((w) => w.length > 1)
            .toSet()
            .toList();

        if (anchorWords.isNotEmpty) {
          final anchorClause = anchorWords.length == 1
              ? '"${anchorWords.first}"'
              : '(${anchorWords.map((w) => '"$w"').join(' AND ')})';

          const vendorPrefixes = {'apache', 'gnu', 'project', 'open', 'the'};
          final distinctiveWords = anchorWords.where((w) => !vendorPrefixes.contains(w.toLowerCase())).toList();
          final primaryAnchorWord = distinctiveWords.isNotEmpty ? distinctiveWords.last : anchorWords.first;

          final otherTerms = queryTerms.where((w) => !anchorWords.contains(w)).toList();
          if (otherTerms.isNotEmpty) {
            // Pass 1: Chunks containing anchor AND other terms
            final anchoredQuery = '$anchorClause AND (${otherTerms.map((w) => '"$w"').join(" OR ")})';
            try {
              final aRows = await _db!.rawQuery('''
                SELECT text_content, metadata, bm25(document_chunks) as score
                FROM document_chunks 
                WHERE space_id = ? AND document_chunks MATCH ? 
                ORDER BY score ASC
                LIMIT ?
              ''', [spaceId, anchoredQuery, candidatePool]);
              addUniqueRows(aRows);
            } catch (_) {}

            // Pass 1b: Distinctive subject word AND other terms
            if (rows.length < candidatePool && anchorWords.length > 1) {
              final distinctiveQuery = '"$primaryAnchorWord" AND (${otherTerms.map((w) => '"$w"').join(" OR ")})';
              try {
                final dRows = await _db!.rawQuery('''
                  SELECT text_content, metadata, bm25(document_chunks) as score
                  FROM document_chunks 
                  WHERE space_id = ? AND document_chunks MATCH ? 
                  ORDER BY score ASC
                  LIMIT ?
                ''', [spaceId, distinctiveQuery, candidatePool]);
                addUniqueRows(dRows);
              } catch (_) {}
            }
          }
        }
      }

      // Pass 2 (Broad BM25 matching like OG backend): Always query all content terms with OR
      if (rows.length < candidatePool * 2) {
        final cleanQuery = queryTerms.map((w) => '"$w"').join(' OR ');
        try {
          final broadRows = await _db!.rawQuery('''
            SELECT text_content, metadata, bm25(document_chunks) as score
            FROM document_chunks 
            WHERE space_id = ? AND document_chunks MATCH ? 
            ORDER BY score ASC
            LIMIT ?
          ''', [spaceId, cleanQuery, candidatePool * 2]);
          addUniqueRows(broadRows);
        } catch (_) {}
      }

      // Pass 3 (Fuzzy Prefix Fallback): Handle typos, inflections, and stem mismatches
      if (rows.length < 15) {
        final prefixQuery = queryTerms
            .where((w) => w.length >= 4)
            .map((w) => '"${w.substring(0, math.min(w.length, 6))}"*')
            .join(' OR ');
        if (prefixQuery.isNotEmpty) {
          try {
            final prefixRows = await _db!.rawQuery('''
              SELECT text_content, metadata, bm25(document_chunks) as score
              FROM document_chunks 
              WHERE space_id = ? AND document_chunks MATCH ? 
              ORDER BY score ASC
              LIMIT ?
            ''', [spaceId, prefixQuery, candidatePool]);
            addUniqueRows(prefixRows);
          } catch (_) {}
        }
      }

      // Re-sort all candidate rows by SQLite FTS5 bm25 score (smaller / more negative = higher relevance)
      rows.sort((a, b) => (a['score'] as num).compareTo(b['score'] as num));
      final finalRows = rows.take(candidatePool).toList();

      final candidates = finalRows.map((row) => {
        'content': row['text_content'],
        'metadata': jsonDecode(row['metadata'] as String),
        'score': row['score'],
      }).toList();

      return _filterNoiseCandidates(
        candidates, 
        queryText: queryText,
        entityAnchor: effectiveAnchor,
      );
    } catch (e) {
      print('FTS Query error: $e');
      return [];
    }
  }

  static Future<List<Map<String, dynamic>>> query(
    String spaceId, 
    String queryText, {
    int nResults = 5,
    int candidatePool = 40,
  }) async {
    final candidates = await getBm25Candidates(spaceId, queryText, candidatePool: candidatePool);
    return _mmrSelect(candidates, nResults);
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
