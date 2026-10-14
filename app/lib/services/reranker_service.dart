import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';
import 'bert_tokenizer.dart';

class RerankResult {
  final List<Map<String, dynamic>> rankedCandidates;
  final bool isCovered;
  final double topScore;
  final String? closestSource;
  final List<String> missingFacets;
  final List<Map<String, dynamic>> unusedCandidates;

  RerankResult({
    required this.rankedCandidates,
    required this.isCovered,
    required this.topScore,
    this.closestSource,
    this.missingFacets = const [],
    this.unusedCandidates = const [],
  });
}

class RerankerService {
  static OnnxRuntime? _ort;
  static OrtSession? _session;
  static BertWordPieceTokenizer? _tokenizer;
  static bool _isInitialized = false;

  static bool get isInitialized => _isInitialized;

  static Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final docDir = await getApplicationDocumentsDirectory();
      final modelPath = '${docDir.path}/ms-marco-MiniLM-L-6-v2-quantized.onnx';
      final vocabPath = '${docDir.path}/ms-marco-MiniLM-vocab.txt';

      final modelFile = File(modelPath);
      final vocabFile = File(vocabPath);

      if (!await modelFile.exists() || !await vocabFile.exists()) {
        debugPrint('Reranker files missing. Reranker will run in fallback mode until downloaded.');
        return;
      }

      // Initialize Tokenizer
      _tokenizer = await BertWordPieceTokenizer.fromFile(vocabPath);

      // Initialize ONNX Runtime Session
      _ort = OnnxRuntime();
      _session = await _ort!.createSession(modelPath);

      _isInitialized = true;
      debugPrint('RerankerService initialized successfully with quantized MiniLM ONNX.');
    } catch (e) {
      debugPrint('Failed to initialize RerankerService: $e');
      _isInitialized = false;
    }
  }

  /// Evaluates semantic relevance scores for candidates against a query using ONNX cross-encoder.
  /// Returns sorted candidates with 'rerank_score' attached.
  static Future<List<Map<String, dynamic>>> scoreCandidates(
    String query,
    List<Map<String, dynamic>> candidates,
  ) async {
    if (candidates.isEmpty) return [];

    if (!_isInitialized || _session == null || _tokenizer == null) {
      debugPrint('Reranker: Session or Tokenizer uninitialized. Passing candidates with score 0.0.');
      return candidates.map((c) {
        final map = Map<String, dynamic>.from(c);
        map['rerank_score'] = 0.0;
        return map;
      }).toList();
    }

    final stopwatch = Stopwatch()..start();
    final scoredList = <Map<String, dynamic>>[];
    int successCount = 0;
    int failCount = 0;

    for (final candidate in candidates) {
      final text = candidate['content'] as String;

      OrtValue? inputIdsTensor;
      OrtValue? attentionMaskTensor;
      OrtValue? tokenTypeIdsTensor;
      Map<String, OrtValue>? outputs;

      try {
        final pair = _tokenizer!.encodePair(query, text, maxSeqLength: 256);
        final seqLen = pair.inputIds.length;

        inputIdsTensor = await OrtValue.fromList(
          Int64List.fromList(pair.inputIds),
          [1, seqLen],
        );
        attentionMaskTensor = await OrtValue.fromList(
          Int64List.fromList(pair.attentionMask),
          [1, seqLen],
        );
        tokenTypeIdsTensor = await OrtValue.fromList(
          Int64List.fromList(pair.tokenTypeIds),
          [1, seqLen],
        );

        final inputs = {
          'input_ids': inputIdsTensor,
          'attention_mask': attentionMaskTensor,
          'token_type_ids': tokenTypeIdsTensor,
        };

        outputs = await _session!.run(inputs);
        final outputValue = outputs['logits'] ?? (outputs.isNotEmpty ? outputs.values.first : null);

        double score = double.negativeInfinity;
        if (outputValue != null) {
          // asFlattenedList() returns a 1D List<dynamic>, avoiding Float32List nesting bug
          final flat = await outputValue.asFlattenedList();
          if (flat.isNotEmpty && flat.first is num) {
            score = (flat.first as num).toDouble();
          }
        }

        final scoredCandidate = Map<String, dynamic>.from(candidate);
        scoredCandidate['rerank_score'] = score;
        scoredList.add(scoredCandidate);
        successCount++;
      } catch (e, stack) {
        debugPrint('Reranking error on candidate: $e\n$stack');
        failCount++;
        final fallback = Map<String, dynamic>.from(candidate);
        fallback['rerank_score'] = double.negativeInfinity;
        scoredList.add(fallback);
      } finally {
        inputIdsTensor?.dispose();
        attentionMaskTensor?.dispose();
        tokenTypeIdsTensor?.dispose();
        if (outputs != null) {
          for (final out in outputs.values) {
            out.dispose();
          }
        }
      }
    }

    stopwatch.stop();
    debugPrint('Reranker: Scored $successCount candidates ($failCount failed) in ${stopwatch.elapsedMilliseconds}ms for query: "$query"');

    if (successCount == 0 && candidates.isNotEmpty) {
      debugPrint('WARNING: Reranker failed to score any candidates! Check ONNX session and tensors.');
    }

    // Sort descending by rerank score
    scoredList.sort((a, b) {
      final scoreA = (a['rerank_score'] as num).toDouble();
      final scoreB = (b['rerank_score'] as num).toDouble();
      return scoreB.compareTo(scoreA);
    });

    // Print top 5 candidates with scores and snippets for inspection
    for (int i = 0; i < scoredList.take(5).length; i++) {
      final c = scoredList[i];
      final preview = (c['content'] as String).replaceAll(RegExp(r'\s+'), ' ').trim();
      final snippet = preview.length > 90 ? '${preview.substring(0, 90)}...' : preview;
      debugPrint('  [Top #${i + 1}] Score: ${c['rerank_score']?.toStringAsFixed(3)} | $snippet');
    }

    return scoredList;
  }

  /// Reranks candidates per facet to guarantee wide architectural coverage.
  /// Reranks candidates per facet to guarantee wide architectural coverage.
  /// For each facet, scores candidate chunks against that specific facet query and
  /// selects the top 1-2 chunks above threshold while enforcing per-source caps.
  static Future<RerankResult> rerankFacets(
    List<Map<String, dynamic>> facetRequests, {
    int targetCount = 4,
    double cutoffThreshold = -0.5,
  }) async {
    if (facetRequests.isEmpty) {
      return RerankResult(
        rankedCandidates: [],
        isCovered: false,
        topScore: double.negativeInfinity,
      );
    }

    final selected = <Map<String, dynamic>>[];
    final seenContent = <String>{};
    final bookCount = <String, int>{};
    final sectionCount = <String, int>{};
    final missingFacets = <String>[];
    double highestScore = double.negativeInfinity;
    String? closestSource;

    // Strict per-book cap to ensure diversity across distinct books in the library
    final maxPerBook = math.min(2, (targetCount / 2).ceil());

    final scoredByFacet = <String, List<Map<String, dynamic>>>{};

    // Step 1: Score all facets first to determine the run's highest score
    for (final facet in facetRequests) {
      final label = facet['label'] as String? ?? 'General';
      final query = (facet['rerankQuery'] ?? facet['query'] ?? facet['bm25Query']) as String;
      final candidates = (facet['candidates'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];

      if (candidates.isEmpty) {
        missingFacets.add(label);
        continue;
      }

      final scored = await scoreCandidates(query, candidates);
      scoredByFacet[label] = scored;

      if (scored.isNotEmpty) {
        final score = (scored.first['rerank_score'] as num).toDouble();
        if (score > highestScore) {
          highestScore = score;
          final meta = scored.first['metadata'] as Map<String, dynamic>?;
          closestSource = meta?['virtual_filename'] as String?;
        }
      }
    }

    // Step 2: Compute effective cutoff with relative score drop (drop chunks lagging > 3.2 behind best)
    final relativeCutoff = (highestScore != double.negativeInfinity)
        ? highestScore - 3.2
        : cutoffThreshold;
    final effectiveCutoff = math.max(cutoffThreshold, relativeCutoff);

    // Pass 1: Select top chunk for each facet above effective cutoff
    for (final facet in facetRequests) {
      final label = facet['label'] as String? ?? 'General';
      final query = (facet['rerankQuery'] ?? facet['query'] ?? facet['bm25Query']) as String;
      final scored = scoredByFacet[label] ?? [];

      Map<String, dynamic>? chosen;
      for (final cand in scored) {
        final score = (cand['rerank_score'] as num).toDouble();
        if (_isInitialized && score < effectiveCutoff) continue;

        final content = cand['content'] as String;
        if (seenContent.contains(content)) continue;

        final meta = cand['metadata'] as Map<String, dynamic>? ?? {};
        final book = (meta['virtual_filename'] ?? 'unknown') as String;
        final chunkIdx = (meta['chunk_index'] ?? 0) as int;
        final sectionKey = '${book}_${chunkIdx ~/ 5}';

        // Section cap: max 2 from same section
        if ((sectionCount[sectionKey] ?? 0) >= 2) continue;
        // Per-book cap
        if ((bookCount[book] ?? 0) >= maxPerBook) continue;

        chosen = cand;
        seenContent.add(content);
        sectionCount[sectionKey] = (sectionCount[sectionKey] ?? 0) + 1;
        bookCount[book] = (bookCount[book] ?? 0) + 1;
        break;
      }

      if (chosen != null) {
        final enriched = Map<String, dynamic>.from(chosen);
        enriched['facet_label'] = label;
        enriched['facet_query'] = query;
        selected.add(enriched);
      } else {
        missingFacets.add(label);
      }

      if (selected.length >= targetCount) break;
    }

    // Pass 2: If under targetCount, fill remaining slots with highest scoring remaining chunks above cutoff
    if (selected.length < targetCount) {
      final remaining = <Map<String, dynamic>>[];
      for (final entry in scoredByFacet.entries) {
        final label = entry.key;
        for (final cand in entry.value) {
          final content = cand['content'] as String;
          if (seenContent.contains(content)) continue;
          final score = (cand['rerank_score'] as num).toDouble();
          if (_isInitialized && score < effectiveCutoff) continue;

          final candCopy = Map<String, dynamic>.from(cand);
          candCopy['facet_label'] = label;
          candCopy['facet_query'] = candCopy['facet_query'] ?? label;
          remaining.add(candCopy);
        }
      }

      remaining.sort((a, b) {
        final scoreA = (a['rerank_score'] as num).toDouble();
        final scoreB = (b['rerank_score'] as num).toDouble();
        return scoreB.compareTo(scoreA);
      });

      for (final cand in remaining) {
        if (selected.length >= targetCount) break;
        final content = cand['content'] as String;
        if (seenContent.contains(content)) continue;

        final meta = cand['metadata'] as Map<String, dynamic>? ?? {};
        final book = (meta['virtual_filename'] ?? 'unknown') as String;
        final chunkIdx = (meta['chunk_index'] ?? 0) as int;
        final sectionKey = '${book}_${chunkIdx ~/ 5}';

        if ((sectionCount[sectionKey] ?? 0) >= 2) continue;
        if ((bookCount[book] ?? 0) >= maxPerBook) continue;

        seenContent.add(content);
        sectionCount[sectionKey] = (sectionCount[sectionKey] ?? 0) + 1;
        bookCount[book] = (bookCount[book] ?? 0) + 1;
        selected.add(cand);
      }
    }

    final unused = <Map<String, dynamic>>[];
    for (final entry in scoredByFacet.entries) {
      for (final cand in entry.value) {
        final content = cand['content'] as String;
        final score = (cand['rerank_score'] as num).toDouble();
        if (score >= effectiveCutoff && !seenContent.contains(content)) {
          final copy = Map<String, dynamic>.from(cand);
          copy['facet_label'] = entry.key;
          unused.add(copy);
        }
      }
    }

    final isCovered = selected.isNotEmpty && (highestScore >= effectiveCutoff || !_isInitialized);

    return RerankResult(
      rankedCandidates: selected,
      isCovered: isCovered,
      topScore: highestScore,
      closestSource: closestSource,
      missingFacets: missingFacets,
      unusedCandidates: unused,
    );
  }

  /// Reranks BM25 candidates on-device using cross-encoder.
  /// Applies absolute score gating, relative drop gating, and per-source caps.
  static Future<RerankResult> rerank(
    String query,
    List<Map<String, dynamic>> candidates, {
    int targetCount = 4,
    double cutoffThreshold = -0.5,
  }) async {
    if (candidates.isEmpty) {
      return RerankResult(
        rankedCandidates: [],
        isCovered: false,
        topScore: double.negativeInfinity,
      );
    }

    final scoredList = await scoreCandidates(query, candidates);

    final topScore = scoredList.isNotEmpty
        ? (scoredList.first['rerank_score'] as num).toDouble()
        : double.negativeInfinity;

    String? closestSource;
    if (scoredList.isNotEmpty) {
      final meta = scoredList.first['metadata'] as Map<String, dynamic>?;
      closestSource = meta?['virtual_filename'] as String? ?? 'Uploaded Documents';
    }

    // Fallback if neural failed
    if (topScore == double.negativeInfinity && candidates.isNotEmpty) {
      debugPrint('Reranker: Neural scoring encountered an error on all candidates, falling back to BM25 selection.');
      return RerankResult(
        rankedCandidates: candidates.take(targetCount).toList(),
        isCovered: true,
        topScore: 0.0,
        closestSource: closestSource,
      );
    }

    // Relative cutoff: drop any chunk lagging > 3.2 points below the best score
    final relativeCutoff = (topScore != double.negativeInfinity)
        ? topScore - 3.2
        : cutoffThreshold;
    final effectiveCutoff = math.max(cutoffThreshold, relativeCutoff);

    // Absolute threshold gating
    final isCovered = topScore >= effectiveCutoff || !_isInitialized;
    if (!isCovered) {
      debugPrint('RAG Gate: Out-of-coverage! Top score $topScore < cutoff $effectiveCutoff');
      return RerankResult(
        rankedCandidates: [],
        isCovered: false,
        topScore: topScore,
        closestSource: closestSource,
      );
    }

    // Per-source caps
    final selected = <Map<String, dynamic>>[];
    final bookCount = <String, int>{};
    final sectionCount = <String, int>{};
    // Strict per-book cap to ensure diversity across distinct books in the library
    final maxPerBook = math.min(2, (targetCount / 2).ceil());

    for (final cand in scoredList) {
      if (selected.length >= targetCount) break;

      final score = (cand['rerank_score'] as num).toDouble();
      if (_isInitialized && score < effectiveCutoff) continue;

      final meta = cand['metadata'] as Map<String, dynamic>? ?? {};
      final book = (meta['virtual_filename'] ?? 'unknown') as String;
      final chunkIdx = (meta['chunk_index'] ?? 0) as int;
      final sectionKey = '${book}_${chunkIdx ~/ 5}';

      if ((sectionCount[sectionKey] ?? 0) >= 2) continue;
      if ((bookCount[book] ?? 0) >= maxPerBook) continue;

      selected.add(cand);
      sectionCount[sectionKey] = (sectionCount[sectionKey] ?? 0) + 1;
      bookCount[book] = (bookCount[book] ?? 0) + 1;
    }

    final unused = scoredList
        .where((c) => !selected.contains(c) && (c['rerank_score'] as num) >= effectiveCutoff)
        .toList();

    return RerankResult(
      rankedCandidates: selected,
      isCovered: true,
      topScore: topScore,
      closestSource: closestSource,
      unusedCandidates: unused,
    );
  }

  static void dispose() {
    _session?.close();
    _session = null;
    _tokenizer = null;
    _isInitialized = false;
  }
}

