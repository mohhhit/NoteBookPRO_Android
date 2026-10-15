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
  final bool isPartialMatch;

  RerankResult({
    required this.rankedCandidates,
    required this.isCovered,
    required this.topScore,
    this.closestSource,
    this.missingFacets = const [],
    this.unusedCandidates = const [],
    this.isPartialMatch = false,
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
  /// Reranks candidates per facet to guarantee wide architectural coverage.
  /// For each facet, scores candidate chunks against that specific facet query and
  /// selects the top 1-2 chunks above threshold while enforcing per-source caps.
  static Future<RerankResult> rerankFacets(
    List<Map<String, dynamic>> facetRequests, {
    int targetCount = 4,
    double cutoffThreshold = -4.0,
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

    // Soft per-book cap: allow up to max(3, (targetCount * 0.65).ceil()) per book
    // so an authoritative book can contribute 3-4 rich chunks without being arbitrarily capped at 2
    final maxPerBook = math.max(3, (targetCount * 0.65).ceil());

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

    // Step 2: Soft gate - if top score < -1.5, mark partial match
    var isPartialMatch = highestScore < -1.5;
    final effectiveTargetCount = targetCount;

    final relativeCutoff = (highestScore != double.negativeInfinity)
        ? highestScore - 4.0
        : cutoffThreshold;
    final effectiveCutoff = (highestScore != double.negativeInfinity && highestScore < cutoffThreshold)
        ? relativeCutoff
        : math.max(cutoffThreshold, relativeCutoff);

    // Collect all competitive candidates across all facets
    final allCompetitive = <Map<String, dynamic>>[];
    final allScored = <Map<String, dynamic>>[];
    for (final entry in scoredByFacet.entries) {
      final label = entry.key;
      for (final cand in entry.value) {
        final copy = Map<String, dynamic>.from(cand);
        copy['facet_label'] = label;
        allScored.add(copy);

        final score = (cand['rerank_score'] as num).toDouble();
        if (_isInitialized && score < effectiveCutoff) continue;
        allCompetitive.add(copy);
      }
    }

    allCompetitive.sort((a, b) {
      final sA = (a['rerank_score'] as num).toDouble();
      final sB = (b['rerank_score'] as num).toDouble();
      return sB.compareTo(sA);
    });

    final facetCount = <String, int>{};

    // Pass 1 (Diversity): Select top chunk for each facet only if competitive (within 4.0 of highestScore)
    for (final facet in facetRequests) {
      final label = facet['label'] as String? ?? 'General';
      final query = (facet['rerankQuery'] ?? facet['query'] ?? facet['bm25Query']) as String;
      final scored = scoredByFacet[label] ?? [];

      Map<String, dynamic>? chosen;
      for (final cand in scored) {
        final score = (cand['rerank_score'] as num).toDouble();
        if (_isInitialized && (score < effectiveCutoff || (highestScore != double.negativeInfinity && score < highestScore - 4.0))) {
          continue;
        }

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
        facetCount[label] = (facetCount[label] ?? 0) + 1;
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
    }

    // Pass 2 (Depth): Fill remaining slots up to effectiveTargetCount with highest scoring candidates
    for (final cand in allCompetitive) {
      if (selected.length >= effectiveTargetCount) break;
      final content = cand['content'] as String;
      if (seenContent.contains(content)) continue;

      final label = cand['facet_label'] as String? ?? 'General';
      if ((facetCount[label] ?? 0) >= 2) continue;

      final meta = cand['metadata'] as Map<String, dynamic>? ?? {};
      final book = (meta['virtual_filename'] ?? 'unknown') as String;
      final chunkIdx = (meta['chunk_index'] ?? 0) as int;
      final sectionKey = '${book}_${chunkIdx ~/ 5}';

      if ((sectionCount[sectionKey] ?? 0) >= 2) continue;
      if ((bookCount[book] ?? 0) >= maxPerBook) continue;

      seenContent.add(content);
      sectionCount[sectionKey] = (sectionCount[sectionKey] ?? 0) + 1;
      bookCount[book] = (bookCount[book] ?? 0) + 1;
      facetCount[label] = (facetCount[label] ?? 0) + 1;
      selected.add(cand);
    }

    // Book Diversity: If candidates from >= 2 distinct books are competitive, guarantee multi-book synthesis
    final competitiveBooks = allCompetitive.map((c) {
      final meta = c['metadata'] as Map<String, dynamic>? ?? {};
      return (meta['virtual_filename'] ?? meta['filename'] ?? 'unknown') as String;
    }).toSet();

    if (competitiveBooks.length >= 2) {
      final selectedBooks = selected.map((c) {
        final meta = c['metadata'] as Map<String, dynamic>? ?? {};
        return (meta['virtual_filename'] ?? meta['filename'] ?? 'unknown') as String;
      }).toSet();

      if (selectedBooks.length < 2) {
        for (final cand in allCompetitive) {
          final meta = cand['metadata'] as Map<String, dynamic>? ?? {};
          final b = (meta['virtual_filename'] ?? meta['filename'] ?? 'unknown') as String;
          if (!selectedBooks.contains(b)) {
            if (selected.length >= effectiveTargetCount && selected.isNotEmpty) {
              selected.removeLast();
            }
            selected.add(cand);
            break;
          }
        }
      }
    }

    // Pass 3 (Relax Caps): If under effectiveTargetCount, relax per-book and per-section caps to fill slots
    if (selected.length < effectiveTargetCount) {
      for (final cand in allCompetitive) {
        if (selected.length >= effectiveTargetCount) break;
        final content = cand['content'] as String;
        if (seenContent.contains(content)) continue;
        seenContent.add(content);
        selected.add(cand);
      }
    }

    // Pass 4 (OG Threshold Fallback): If still empty, take top-ranked candidates rather than refusing
    if (selected.isEmpty && allScored.isNotEmpty) {
      allScored.sort((a, b) => (b['rerank_score'] as num).compareTo(a['rerank_score'] as num));
      for (final cand in allScored) {
        if (selected.length >= effectiveTargetCount) break;
        final content = cand['content'] as String;
        if (seenContent.contains(content)) continue;
        seenContent.add(content);
        selected.add(cand);
      }
      isPartialMatch = true;
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

    final isCovered = selected.isNotEmpty;

    return RerankResult(
      rankedCandidates: selected,
      isCovered: isCovered,
      topScore: highestScore,
      closestSource: closestSource,
      missingFacets: missingFacets,
      unusedCandidates: unused,
      isPartialMatch: isPartialMatch,
    );
  }

  /// Reranks BM25 candidates on-device using cross-encoder.
  /// Applies absolute score gating, relative drop gating, and per-source caps.
  static Future<RerankResult> rerank(
    String query,
    List<Map<String, dynamic>> candidates, {
    int targetCount = 4,
    double cutoffThreshold = -4.0,
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

    // Soft gate: if top score < -1.5, mark partial match
    var isPartialMatch = topScore < -1.5;
    final effectiveTargetCount = targetCount;

    final relativeCutoff = (topScore != double.negativeInfinity)
        ? topScore - 4.0
        : cutoffThreshold;
    final effectiveCutoff = (topScore != double.negativeInfinity && topScore < cutoffThreshold)
        ? relativeCutoff
        : math.max(cutoffThreshold, relativeCutoff);

    // Per-source caps
    final selected = <Map<String, dynamic>>[];
    final bookCount = <String, int>{};
    final sectionCount = <String, int>{};
    final maxPerBook = math.max(3, (effectiveTargetCount / 2).ceil());

    for (final cand in scoredList) {
      if (selected.length >= effectiveTargetCount) break;

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

    // OG Cap Relaxation: If under effectiveTargetCount, fill remaining slots from scoredList
    if (selected.length < effectiveTargetCount) {
      for (final cand in scoredList) {
        if (selected.length >= effectiveTargetCount) break;
        if (selected.contains(cand)) continue;
        final score = (cand['rerank_score'] as num).toDouble();
        if (_isInitialized && score < effectiveCutoff) continue;
        selected.add(cand);
      }
    }

    // Book Diversity: If competitive candidates exist from >= 2 books, ensure at least 2 distinct books
    final competitiveCandidates = scoredList.where((c) => (c['rerank_score'] as num) >= effectiveCutoff).toList();
    final competitiveBooks = competitiveCandidates.map((c) {
      final meta = c['metadata'] as Map<String, dynamic>? ?? {};
      return (meta['virtual_filename'] ?? meta['filename'] ?? 'unknown') as String;
    }).toSet();

    if (competitiveBooks.length >= 2) {
      final selectedBooks = selected.map((c) {
        final meta = c['metadata'] as Map<String, dynamic>? ?? {};
        return (meta['virtual_filename'] ?? meta['filename'] ?? 'unknown') as String;
      }).toSet();

      if (selectedBooks.length < 2) {
        for (final cand in competitiveCandidates) {
          final meta = cand['metadata'] as Map<String, dynamic>? ?? {};
          final b = (meta['virtual_filename'] ?? meta['filename'] ?? 'unknown') as String;
          if (!selectedBooks.contains(b)) {
            if (selected.length >= effectiveTargetCount && selected.isNotEmpty) {
              selected.removeLast();
            }
            selected.add(cand);
            break;
          }
        }
      }
    }

    // OG Threshold Fallback: If still empty (all candidates fell below cutoff), take top candidates anyway
    if (selected.isEmpty && scoredList.isNotEmpty) {
      for (final cand in scoredList) {
        if (selected.length >= effectiveTargetCount) break;
        selected.add(cand);
      }
      isPartialMatch = true;
    }

    final unused = scoredList
        .where((c) => !selected.contains(c) && (c['rerank_score'] as num) >= effectiveCutoff)
        .toList();

    return RerankResult(
      rankedCandidates: selected,
      isCovered: selected.isNotEmpty,
      topScore: topScore,
      closestSource: closestSource,
      unusedCandidates: unused,
      isPartialMatch: isPartialMatch,
    );
  }

  static void dispose() {
    _session?.close();
    _session = null;
    _tokenizer = null;
    _isInitialized = false;
  }
}

