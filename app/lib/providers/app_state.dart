import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import '../models/app_models.dart';
import '../services/local_database_service.dart';
import '../services/local_llm_service.dart';
import '../services/online_llm_service.dart';
import '../services/document_processor.dart';
import '../services/vector_db_service.dart';
import '../services/reranker_service.dart';
import '../services/prompt_builder.dart';
import '../utils/answer_sanitizer.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter/foundation.dart';

class AppState extends ChangeNotifier with WindowListener {
  // Current state
  List<Space> _spaces = [];
  Space? _currentSpace;
  final Set<String> _expandedSpaces = {};
  List<ChatInfo> _chats = [];
  Chat? _currentChat;
  List<Map<String, dynamic>> _uploadedFiles = [];
  String _activeTool = 'Chat';
  bool _isLoading = false;
  String? _error;
  String? _successMessage;
  bool _isUploading = false;
  String _uploadStatus = '';
  bool _isThinking = false;

  // Online vs Offline LLM Configuration
  bool _useOnlineLlm = false;
  String _onlineModelName = OnlineLlmService.defaultModel;
  String? _geminiApiKey;

  // UI state
  bool _sidebarOpen = true;
  bool _plusMenuOpen = false;
  bool _toolsMenuOpen = false;
  bool _filesDrawerOpen = false;

  // Getters
  List<Space> get spaces => _spaces;
  Space? get currentSpace => _currentSpace;
  bool isSpaceExpanded(String spaceId) => _expandedSpaces.contains(spaceId);
  List<ChatInfo> get chats => _chats;
  Chat? get currentChat => _currentChat;
  List<Map<String, dynamic>> get uploadedFiles => _uploadedFiles;
  String get activeTool => _activeTool;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String? get successMessage => _successMessage;
  bool get isUploading => _isUploading;
  String get uploadStatus => _uploadStatus;
  bool get isThinking => _isThinking;
  bool get sidebarOpen => _sidebarOpen;
  bool get plusMenuOpen => _plusMenuOpen;
  bool get toolsMenuOpen => _toolsMenuOpen;
  bool get filesDrawerOpen => _filesDrawerOpen;

  // LLM Configuration Getters
  bool get useOnlineLlm => _useOnlineLlm;
  String get onlineModelName => _onlineModelName;
  String? get geminiApiKey => _geminiApiKey;
  String get activeModelDisplayName => _useOnlineLlm
      ? OnlineLlmService.getModelDisplayName(_onlineModelName)
      : 'Gemma 4 E2B';

  void toggleSpaceExpansion(String spaceId) {
    if (_expandedSpaces.contains(spaceId)) {
      _expandedSpaces.remove(spaceId);
    } else {
      _expandedSpaces.add(spaceId);
    }
    notifyListeners();
  }

  // --- Window Management ---
  Future<void> _restoreWindowState() async {
    final prefs = await SharedPreferences.getInstance();
    final width = prefs.getDouble('window_width');
    final height = prefs.getDouble('window_height');
    final isMaximized = prefs.getBool('window_maximized') ?? false;
    if (width != null && height != null) {
      await windowManager.setSize(Size(width, height));
    }
    if (isMaximized) {
      await windowManager.maximize();
    }
  }

  Future<void> _persistWindowState() async {
    final prefs = await SharedPreferences.getInstance();
    final size = await windowManager.getSize();
    final isMaximized = await windowManager.isMaximized();
    await prefs.setDouble('window_width', size.width);
    await prefs.setDouble('window_height', size.height);
    await prefs.setBool('window_maximized', isMaximized);
  }

  Timer? _windowStateTimer;
  void _scheduleWindowStatePersist() {
    _windowStateTimer?.cancel();
    _windowStateTimer = Timer(const Duration(seconds: 1), _persistWindowState);
  }

  @override
  void onWindowClose() async {
    await _persistWindowState();
    await windowManager.destroy();
  }

  @override
  void onWindowMove() => _scheduleWindowStatePersist();
  @override
  void onWindowResize() => _scheduleWindowStatePersist();
  @override
  void onWindowMaximize() => _scheduleWindowStatePersist();
  @override
  void onWindowUnmaximize() => _scheduleWindowStatePersist();

  // --- Initialization ---
  Future<void> initialize() async {
    windowManager.addListener(this);
    await _restoreWindowState();
    await loadLlmSettings();
    await loadSpaces();
  }

  // --- LLM Model & Execution Mode Settings ---
  Future<void> loadLlmSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _useOnlineLlm = prefs.getBool('use_online_llm') ?? false;
      _onlineModelName = prefs.getString('gemini_model_name') ?? OnlineLlmService.defaultModel;
      _geminiApiKey = prefs.getString('gemini_api_key');
      notifyListeners();
    } catch (e) {
      print('Failed to load LLM settings: $e');
    }
  }

  Future<void> setUseOnlineLlm(bool useOnline) async {
    _useOnlineLlm = useOnline;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('use_online_llm', useOnline);
    } catch (_) {}
  }

  Future<void> setOnlineModelName(String modelName) async {
    _onlineModelName = modelName;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('gemini_model_name', modelName);
    } catch (_) {}
  }

  Future<void> setGeminiApiKey(String apiKey) async {
    _geminiApiKey = apiKey.trim();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('gemini_api_key', apiKey.trim());
    } catch (_) {}
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _windowStateTimer?.cancel();
    super.dispose();
  }

  // --- Spaces ---
  Future<void> loadSpaces() async {
    try {
      final rawSpaces = await LocalDatabaseService.getSpaces();
      _spaces = rawSpaces.map((s) => Space.fromJson(s)).toList();
      
      if (_spaces.isEmpty) {
        // Auto-create a default space if none exist
        await createSpace('Local Space');
      } else {
        if (_currentSpace == null) {
          await selectSpace(_spaces.first.id);
        }
      }
      
      notifyListeners();
    } catch (e) {
      _setError('Failed to load spaces locally: $e');
    }
  }

  Future<void> createSpace(String name) async {
    _setLoading(true);
    try {
      final data = await LocalDatabaseService.createSpace(name);
      final space = Space.fromJson(data);
      _spaces.add(space);
      await selectSpace(space.id);
    } catch (e) {
      _setError('Failed to create space: $e');
    } finally {
      _setLoading(false);
    }
  }

  Future<void> selectSpace(String spaceId) async {
    _currentSpace = _spaces.firstWhere((s) => s.id == spaceId);
    _expandedSpaces.clear();
    _expandedSpaces.add(spaceId);
    _currentChat = null;
    await loadChats();
    await loadUploadedFiles();
    notifyListeners();
  }

  Future<void> deleteSpace(String spaceId) async {
    try {
      await LocalDatabaseService.deleteSpace(spaceId);
      _spaces.removeWhere((s) => s.id == spaceId);
      if (_currentSpace?.id == spaceId) {
        _currentSpace = _spaces.isNotEmpty ? _spaces.first : null;
        if (_currentSpace != null) {
          await selectSpace(_currentSpace!.id);
        }
      }
      notifyListeners();
    } catch (e) {
      _setError('Failed to delete space: $e');
    }
  }

  // --- Chats ---
  Future<void> loadChats() async {
    if (_currentSpace == null) return;
    try {
      final rawChats = await LocalDatabaseService.getChats(_currentSpace!.id);
      _chats = rawChats.map((c) => ChatInfo.fromJson(c)).toList();
      notifyListeners();
    } catch (e) {
      _setError('Failed to load chats locally: $e');
    }
  }

  Future<void> loadChat(String chatId) async {
    if (_currentSpace == null) return;
    try {
      final rawChat = await LocalDatabaseService.getChatWithMessages(chatId);
      _currentChat = Chat.fromJson(rawChat);
      notifyListeners();
    } catch (e) {
      _setError('Failed to load chat: $e');
    }
  }

  Future<void> newChat() async {
    _currentChat = null;
    notifyListeners();
  }

  Future<void> deleteChat(String chatId) async {
    if (_currentSpace == null) return;
    try {
      await LocalDatabaseService.deleteChat(chatId);
      _chats.removeWhere((c) => c.id == chatId);
      if (_currentChat?.id == chatId) {
        _currentChat = null;
      }
      notifyListeners();
    } catch (e) {
      _setError('Failed to delete chat: $e');
    }
  }

  Future<void> deleteAssistantResponse({required int messageIndex}) async {
    // Basic stub for local DB delete msg
    _showTemporarySuccess("Message deleted (Local UI Update only)");
  }

  // --- Messaging (Offline LLM) ---
  Future<void> sendMessage(String query) async {
    if (_currentSpace == null) return;

    _setLoading(true);

    try {
      // 1. Create chat if it doesn't exist
      if (_currentChat == null || _currentChat!.id.isEmpty) {
        final chatData = await LocalDatabaseService.createChat(_currentSpace!.id, query);
        _currentChat = Chat(
          id: chatData['id'],
          createdAt: chatData['updated_at'],
          updatedAt: chatData['updated_at'],
          messages: [],
        );
        await loadChats();
      }

      // 2. Keep screen awake while processing query & generating response
      try {
        await WakelockPlus.enable();
      } catch (_) {}

      // Add user message
      await LocalDatabaseService.addMessage(_currentChat!.id, 'user', query);
      final userMsg = ChatMessage(role: 'user', content: query, timestamp: DateTime.now().toIso8601String());
      _currentChat!.messages.add(userMsg);
      notifyListeners();

      // 3. Prepare AI Assistant Message
      _isThinking = true;
      notifyListeners();

      final aiMsgIndex = _currentChat!.messages.length;
      final aiMsg = ChatMessage(role: 'assistant', content: '', timestamp: DateTime.now().toIso8601String());
      _currentChat!.messages.add(aiMsg);
      
      final relevantPassages = <Map<String, String>>[];
      List<Map<String, dynamic>> unusedCandidates = [];

      void updateAssistantMessage(String newText, {List<String>? followUps}) {
        _currentChat!.messages[aiMsgIndex] = ChatMessage(
          role: 'assistant',
          content: newText,
          timestamp: aiMsg.timestamp,
          sources: relevantPassages,
          suggestedFollowUps: followUps,
        );
        notifyListeners();
      }

      // 4. Retrieve Context (Entity-Anchored Facet BM25 -> On-Device Cross-Encoder Reranking)
      // Note: Rule-based entity facets skip LLM generation to eliminate latency and prevent entity loss
      final coreEntity = extractCoreEntity(query);
      List<String> contextChunks = [];
      List<String> missingFacets = [];
      List<Map<String, dynamic>> allResults = [];

      try {
        final isConceptual = VectorDbService.isConceptualQuery(query);
        final comparisonEntities = extractComparisonEntities(query);
        RerankResult rerankResult;

        if (comparisonEntities != null) {
          final eA = comparisonEntities['entityA']!;
          final eB = comparisonEntities['entityB']!;
          final scope = extractScopePhrase(query);
          print('[RAG COMPARISON] Detected comparison between "$eA" and "$eB"${scope != null ? " (scope: $scope)" : ""}');
          final facets = buildFacetsForComparison(eA, eB, scope: scope);
          final facetRequests = <Map<String, dynamic>>[];

          // 1. Always run full question as direct broad BM25 and reranker query to capture verbatim textbook matches
          final directCandidates = await VectorDbService.getBm25Candidates(
            _currentSpace!.id,
            query,
            candidatePool: 50,
          );
          facetRequests.add({
            'label': 'Direct Question Evidence',
            'bm25Query': query,
            'rerankQuery': query,
            'candidates': directCandidates,
          });

          for (final f in facets) {
            final candidates = await VectorDbService.getBm25Candidates(
              _currentSpace!.id,
              f['bm25Query']!,
              candidatePool: 50,
              entityAnchor: f['anchor'],
            );
            facetRequests.add({
              'label': f['label']!,
              'bm25Query': f['bm25Query']!,
              'rerankQuery': f['rerankQuery']!,
              'candidates': candidates,
            });
          }

          rerankResult = await RerankerService.rerankFacets(
            facetRequests,
            targetCount: 8,
            cutoffThreshold: -4.0,
          );
        } else if (isConceptual) {
          final facets = buildFacetsForTopic(query);
          final facetRequests = <Map<String, dynamic>>[];

          // 1. Always run full question as direct broad BM25 and reranker query to capture verbatim textbook matches
          final directCandidates = await VectorDbService.getBm25Candidates(
            _currentSpace!.id,
            query,
            candidatePool: 50,
          );
          facetRequests.add({
            'label': 'Direct Question Evidence',
            'bm25Query': query,
            'rerankQuery': query,
            'candidates': directCandidates,
          });

          // 2. Era facets if query involves temporal, legacy, or modern architecture
          final isEraQuery = RegExp(
            r'\b(?:traditional|legacy|modern|cloud|evolution|history|historical|older|newer|recent|earlier)\b',
            caseSensitive: false,
          ).hasMatch(query);
          if (isEraQuery) {
            final eraList = PromptBuilder.eraFacets(coreEntity);
            for (int i = 0; i < eraList.length; i++) {
              final eraQuery = eraList[i];
              final eraLabel = i == 0 ? 'Traditional & Legacy Architecture' : 'Modern & Cloud Architecture';
              final eraCandidates = await VectorDbService.getBm25Candidates(
                _currentSpace!.id,
                eraQuery,
                candidatePool: 50,
                entityAnchor: coreEntity,
              );
              facetRequests.add({
                'label': eraLabel,
                'bm25Query': eraQuery,
                'rerankQuery': eraQuery,
                'candidates': eraCandidates,
                'anchor': coreEntity,
              });
            }
          }

          for (final f in facets) {
            final candidates = await VectorDbService.getBm25Candidates(
              _currentSpace!.id,
              f['bm25Query']!,
              candidatePool: 50,
              entityAnchor: f['anchor'] ?? coreEntity,
            );
            facetRequests.add({
              'label': f['label']!,
              'bm25Query': f['bm25Query']!,
              'rerankQuery': f['rerankQuery']!,
              'candidates': candidates,
            });
          }

          rerankResult = await RerankerService.rerankFacets(
            facetRequests,
            targetCount: 8,
            cutoffThreshold: -4.0,
          );
        } else {
          final candidates = await VectorDbService.getBm25Candidates(
            _currentSpace!.id,
            query,
            candidatePool: 50,
          );
          rerankResult = await RerankerService.rerank(
            query,
            candidates,
            targetCount: 6,
            cutoffThreshold: -4.0,
          );
        }

        allResults = rerankResult.rankedCandidates;
        missingFacets = rerankResult.missingFacets;
        unusedCandidates = rerankResult.unusedCandidates;

        if (rerankResult.isPartialMatch) {
          print('[RAG SOFT GATE] Query "$query" is a partial match (topScore: ${rerankResult.topScore.toStringAsFixed(2)}). Informing LLM of partial evidence.');
        }

        if (!rerankResult.isCovered || allResults.isEmpty) {
          final closest = rerankResult.closestSource != null
              ? ' Closest reference found in "${rerankResult.closestSource}".'
              : '';
          final fallbackMsg = "This topic is not covered in your books.$closest For an in-depth architectural breakdown, consider adding a dedicated textbook.";
          updateAssistantMessage(fallbackMsg);
          await LocalDatabaseService.addMessage(_currentChat!.id, 'assistant', fallbackMsg);
          _isThinking = false;
          _setLoading(false);
          notifyListeners();
          return;
        }

        // Pass raw content directly — PromptBuilder.prepareChunks (called inside
        // LocalLlmService.generateResponse) handles all compression with verb
        // bonus + neighbor window. This avoids double-compression.
        int sourceIndex = 1;

        for (final result in allResults) {
          final content = result['content'] as String;
          final metadata = result['metadata'] as Map<String, dynamic>;
          final rawYear = metadata['publication_year'];
          final hasValidYear = rawYear != null &&
              rawYear.toString() != '0000' &&
              rawYear.toString() != 'Unknown Year' &&
              int.tryParse(rawYear.toString()) != null &&
              int.parse(rawYear.toString()) > 1990;
          final yearDisplay = hasValidYear ? rawYear.toString() : '';
          final rawFilename = metadata['virtual_filename'] ?? metadata['filename'] ?? 'unknown';
          final cleanTitle = formatCleanBookTitle(rawFilename.toString());
          final facetLabel = result['facet_label'] as String? ?? 'General';
          final label = yearDisplay.isNotEmpty ? '$cleanTitle ($yearDisplay)' : cleanTitle;

          // Raw content for context (PromptBuilder will compress this)
          contextChunks.add('[$sourceIndex] $label ($facetLabel):\n$content');

          // Shorten passage text to ~700 characters for mobile display while centering on the core entity
          String formatSnippet(String text, String entity, {int maxLen = 700}) {
            final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
            if (clean.length <= maxLen) return clean;

            final entityLower = entity.toLowerCase();
            final cleanLower = clean.toLowerCase();
            final entityIdx = cleanLower.indexOf(entityLower);

            // If the entity is mentioned further into the passage, center snippet on it
            if (entityIdx > 250 && entityIdx < clean.length - 50) {
              final start = clean.lastIndexOf(' ', math.max(0, entityIdx - 80));
              final safeStart = start != -1 ? start + 1 : math.max(0, entityIdx - 80);
              final end = clean.indexOf(' ', math.min(clean.length - 1, safeStart + maxLen));
              final safeEnd = end != -1 ? end : math.min(clean.length, safeStart + maxLen);
              return '...${clean.substring(safeStart, safeEnd).trim()}...';
            }

            final truncated = clean.substring(0, maxLen);
            final lastSpace = truncated.lastIndexOf(' ');
            return '${(lastSpace > 500 ? truncated.substring(0, lastSpace) : truncated).trim()}...';
          }

          relevantPassages.add({
            'index': '$sourceIndex',
            'book': cleanTitle,
            'year': yearDisplay.isNotEmpty ? yearDisplay : 'N/A',
            'facet': facetLabel,
            'text': formatSnippet(content, coreEntity),
          });

          sourceIndex++;
        }

        if (rerankResult.isPartialMatch) {
          contextChunks.add('NOTE ON PARTIAL COVERAGE: The retrieved textbook excerpts provide partial coverage for this specific question. Answer the part covered by the excerpts and state clearly what is not specified, rather than refusing.');
        }

        if (missingFacets.isNotEmpty) {
          contextChunks.add('NOTE ON TEXTBOOK COVERAGE: The uploaded books do NOT contain material for: ${missingFacets.join(", ")}. Do not invent details for them; mention honestly that they are not detailed in the excerpts if relevant.');
        }
      } catch (e) {
        print('Vector DB Query failed: $e');
      }

      // Fast exit guard: zero LLM prefill if nothing retrieved
      if (allResults.isEmpty || contextChunks.isEmpty) {
        final fallbackMsg = "This topic is not covered in your books. For an in-depth breakdown, consider adding a dedicated textbook to this Space.";
        updateAssistantMessage(fallbackMsg);
        await LocalDatabaseService.addMessage(_currentChat!.id, 'assistant', fallbackMsg);
        _isThinking = false;
        _setLoading(false);
        notifyListeners();
        return;
      }

      // 5. Stream response from LocalLlmService
      String fullResponse = "";
      
      // Strip trailing passages from previous assistant turns to stop multi-turn prefill inflation
      final historyForLlm = _currentChat!.messages
          .sublist(0, _currentChat!.messages.length - 1)
          .map((m) {
            if (m.role == 'assistant') {
              final clean = m.content.split('\n\n---\n### Relevant Passages').first.trim();
              return ChatMessage(role: m.role, content: clean, timestamp: m.timestamp);
            }
            return m;
          })
          .toList();

      final Stream<String> stream;
      if (_useOnlineLlm) {
        final key = _geminiApiKey ?? '';
        if (key.trim().isEmpty) {
          throw Exception(
            'Google AI Studio Gemini API key is not configured.\n'
            'Please tap the model pill or open Settings to enter your API key.',
          );
        }
        stream = OnlineLlmService.generateResponse(
          historyForLlm,
          contextChunks: contextChunks,
          modelName: _onlineModelName,
          apiKey: key,
        );
      } else {
        stream = LocalLlmService.generateResponse(
          historyForLlm,
          contextChunks: contextChunks,
        );
      }
      
      bool firstChunk = true;
      
      await for (final chunk in stream) {
        if (firstChunk) {
          _isThinking = false;
          firstChunk = false;
        }
        fullResponse += chunk;
        updateAssistantMessage(fullResponse);
      }

      // 6. Post-process response:
      // 6. Post-process response:
      // a) Sanitize LaTeX delimiters, repair markdown tables, and remove artifact lines (non-destructive)
      final sanitizedResponse = AnswerSanitizer.finalize(
        fullResponse,
        hitTokenLimit: false,
        trimTruncated: false,
      );

      final uc = PromptBuilder.inferUseCase(query);
      final scope = extractScopePhrase(query);

      // b) Compute deterministic citation assignments from raw chunks and drop near-duplicates
      final rawChunksList = allResults.map((r) => r['content'] as String).toList();
      String cleanedResponse = enforceCitationsAndCleanOutput(
        sanitizedResponse,
        rawChunks: rawChunksList,
        useCase: uc,
      );

      // Audit Trace: Dump exact 4-part trace requested by expert to debug retrieval, generation, and verification
      final preparedChunks = PromptBuilder.prepareChunks(contextChunks, query);
      final auditSystemPrompt = PromptBuilder.buildSystemPrompt(uc, chunks: preparedChunks, scope: scope);
      final auditUserMessage = PromptBuilder.buildUserMessage(query, preparedChunks, uc, scope: scope);

      print('\n================== [RAG_AUDIT_TRACE: $query] ==================');
      print('--- 1. RETRIEVED RAW CHUNKS (${allResults.length} chunks) ---');
      for (int i = 0; i < allResults.length; i++) {
        final r = allResults[i];
        final meta = r['metadata'] as Map<String, dynamic>? ?? {};
        final book = meta['virtual_filename'] ?? meta['filename'] ?? 'unknown';
        final score = r['rerank_score'];
        print('[RAW CHUNK ${i + 1}] $book (score=$score):\n${r['content']}\n');
      }

      print('--- 2. EXACT PROMPT & CONTEXT SENT TO LLM ---');
      print('[SYSTEM INSTRUCTION]\n$auditSystemPrompt\n');
      print('[USER MESSAGE WITH CONTEXT]\n$auditUserMessage\n');

      print('--- 3. UNFILTERED RAW MODEL RESPONSE ---');
      print(fullResponse);

      print('\n--- 4. POST-PROCESSED & VERIFIED RESPONSE ---');
      print(cleanedResponse);
      print('================== [END RAG_AUDIT_TRACE] ==================\n');

      // 7. Append "Relevant Passages" with best-matching supporting sentences
      final bestPassages = buildBestMatchingPassages(
        allResults: allResults,
        responseText: cleanedResponse,
        query: query,
      );

      if (bestPassages.isNotEmpty) {
        relevantPassages.clear();
        relevantPassages.addAll(bestPassages);
        final passageBuffer = StringBuffer();
        passageBuffer.writeln('\n\n---\n### Relevant Passages');
        for (final p in bestPassages) {
          final yr = p['year'] != 'N/A' ? ' (${p['year']})' : '';
          passageBuffer.writeln('**[${p['index']}] ${p['book']}**$yr — *${p['facet']}*:');
          passageBuffer.writeln('> "${p['text']}"\n');
        }
        // Only surface the coverage note when the answer is sparse (< 80 words).
        final answerWordCount = cleanedResponse
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim()
            .split(' ')
            .length;
        if (missingFacets.isNotEmpty && answerWordCount < 80) {
          passageBuffer.writeln('*Note: No textbook coverage found in your library for: ${missingFacets.join(", ")}.*');
        }
        cleanedResponse += passageBuffer.toString().trimRight();
      }

      // 8. Generate library-grounded follow-up questions from unused high-scoring candidates
      final followUps = _generateFollowUpQuestions(
        query,
        coreEntity,
        unusedCandidates,
      );

      updateAssistantMessage(cleanedResponse, followUps: followUps);

      // 9. Save the cleaned AI message to DB once done
      await LocalDatabaseService.addMessage(_currentChat!.id, 'assistant', cleanedResponse);

    } catch (e) {
      _setError('Failed to send message locally: $e');
      _isThinking = false;
    } finally {
      _setLoading(false);
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      notifyListeners();
    }
  }

  // --- Notebook/Studio Stubs ---
  Future<void> addAssistantReplyToNotebook({
    required String question, 
    required String answer,
    String? assistantTimestamp,
    List<String>? tags,
  }) async {
    _showTemporarySuccess("Studio Notebook is offline in Android Prototype");
  }

  Future<void> downloadAssistantReplyAsPdf({required String question, required String answer}) async {
    _showTemporarySuccess("PDF Export is offline in Android Prototype");
  }

  Future<void> downloadCurrentChatAnswersAsPdf() async {
    _showTemporarySuccess("PDF Export is offline in Android Prototype");
  }

  // --- Files ---
  Future<void> loadUploadedFiles() async {
    if (_currentSpace == null) return;
    try {
      final rawFiles = await LocalDatabaseService.getFiles(_currentSpace!.id);
      
      // Load chunk count from Vector DB
      List<Map<String, dynamic>> enrichedFiles = [];
      for (final file in rawFiles) {
        final virtualFilename = file['virtual_filename'] as String;
        final chunkCount = await VectorDbService.getFileChunkCount(_currentSpace!.id, virtualFilename);
        
        final enriched = Map<String, dynamic>.from(file);
        enriched['chunks'] = chunkCount;
        enrichedFiles.add(enriched);
      }
      
      _uploadedFiles = enrichedFiles;
      notifyListeners();
    } catch (e) {
      _setError('Failed to load files: $e');
    }
  }

  Future<void> uploadFiles(List<PlatformFile> files) async {
    if (_currentSpace == null) return;
    
    _isUploading = true;
    _uploadStatus = 'Starting process...';
    notifyListeners();
    
    // Prevent screen from turning off during heavy processing
    WakelockPlus.enable();
    
    try {
      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        if (file.path == null) continue;
        
        _uploadStatus = 'Extracting ${file.name} (${i + 1}/${files.length})...';
        notifyListeners();
        
        // Let UI update
        await Future.delayed(const Duration(milliseconds: 10));

        // 1. Extract text via Native Platform Channel (ReadPdfText) -> Syncfusion -> On-Device ML Kit OCR
        final processor = DocumentProcessor();
        final fileData = await processor.processFile(
          file.path!,
          onProgress: (current, total) {
            _uploadStatus = 'OCR scanning page $current of $total (${file.name})...';
            notifyListeners();
          },
          onStatus: (status) {
            _uploadStatus = '$status (${file.name})';
            notifyListeners();
          },
        );
        final content = fileData['content'] as String;
        final virtualFilename = fileData['virtual_filename'] as String;
        fileData.remove('content'); // free immediately

        // 2. Offload heavy string manipulation (chunking) to background isolate
        final chunks = await compute(chunkTextTask, {
          'content': content,
          'virtualFilename': virtualFilename,
        });

        if (chunks.isEmpty) {
          throw Exception(
            'No readable text could be extracted from "${fileData['filename']}". '
            'The file may be blank, corrupted, or password-protected.',
          );
        }
        
        // Formulate metadata
        final metadatas = chunks.asMap().entries.map((entry) => {
          'chunk_index': entry.key,
          'filename': fileData['filename'],
          'virtual_filename': virtualFilename,
          'publication_year': fileData['publication_year'],
        }).toList();
        
        // Store in Vector DB
        await VectorDbService.addDocuments(
          _currentSpace!.id, 
          chunks, 
          metadatas,
          onProgress: (current, total) {
            _uploadStatus = 'Indexing chunk $current of $total...';
            notifyListeners();
          }
        );
        
        // Register in primary DB
        await LocalDatabaseService.addFile(_currentSpace!.id, fileData['filename'], virtualFilename);
      }
      
      await loadUploadedFiles();
      _showTemporarySuccess("Successfully processed and embedded ${files.length} file(s)!");
    } catch (e) {
      _setError('File processing failed: $e');
    } finally {
      WakelockPlus.disable();
      _isUploading = false;
      _uploadStatus = '';
      notifyListeners();
    }
  }

  Future<void> deleteFile(String filename) async {
    if (_currentSpace == null) return;
    try {
      await LocalDatabaseService.deleteFile(_currentSpace!.id, filename);
      await VectorDbService.deleteDocumentsByFilename(_currentSpace!.id, filename);
      await loadUploadedFiles();
      _showTemporarySuccess("Deleted $filename");
    } catch (e) {
      _setError('Delete failed: $e');
    }
  }

  // --- UI Helpers ---
  void _showTemporarySuccess(String message) {
    _successMessage = message;
    notifyListeners();
    Future.delayed(const Duration(seconds: 3), () {
      if (_successMessage == message) {
        _successMessage = null;
        notifyListeners();
      }
    });
  }

  void setActiveTool(String tool) {
    _activeTool = tool;
    notifyListeners();
  }

  void toggleSidebar() {
    _sidebarOpen = !_sidebarOpen;
    notifyListeners();
  }

  void setSidebarOpen(bool open) {
    _sidebarOpen = open;
    notifyListeners();
  }

  void togglePlusMenu() {
    _plusMenuOpen = !_plusMenuOpen;
    _toolsMenuOpen = false;
    notifyListeners();
  }

  void toggleToolsMenu() {
    _toolsMenuOpen = !_toolsMenuOpen;
    _plusMenuOpen = false;
    notifyListeners();
  }

  void toggleFilesDrawer() {
    _filesDrawerOpen = !_filesDrawerOpen;
    notifyListeners();
  }

  void closeMenus() {
    _plusMenuOpen = false;
    _toolsMenuOpen = false;
    notifyListeners();
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void _setError(String? error) {
    _error = error;
    notifyListeners();
  }

  void showError(String error) => _setError(error);
  void clearError() => _setError(null);
  void showSuccess(String message) => _showTemporarySuccess(message);
  void clearSuccessMessage() {
    _successMessage = null;
    notifyListeners();
  }

  /// Formats raw or scraped filenames into clean, professional book titles for display.
  /// Strips repository hashes, publisher tags, curly brace tags, libgen tags, and file extensions.
  static String formatCleanBookTitle(String rawName) {
    var title = rawName.trim();

    // 1. Decode common HTML entities and corrupt character sequences (e.g. O&_039_Reilly, O&#039;Reilly, O& 039 ;)
    title = title.replaceAll(RegExp(r'O\s*&\s*[_#]?0*39\s*[_#;]?\s*Reilly', caseSensitive: false), "O'Reilly");
    title = title.replaceAll(RegExp(r'O\s*&\s*Reilly', caseSensitive: false), "O'Reilly");
    title = title.replaceAll(RegExp(r'&\s*[_#]?0*39\s*[_#;]?', caseSensitive: false), "'");
    title = title.replaceAll(RegExp(r'&#0*39;|&apos;', caseSensitive: false), "'");
    title = title.replaceAll(RegExp(r'&amp;', caseSensitive: false), '&');
    title = title.replaceAll(RegExp(r'&quot;', caseSensitive: false), '"');

    // 2. Strip curly brace blocks: {authors}, {isbn/id}, {publisher} e.g. {Prashanth Babu...}, {107716181}
    title = title.replaceAll(RegExp(r'\{[^\}]*\}'), '');

    // 3. Strip standalone repository / pirate tags before extensions e.g. libgen.li, libgen.lc, z-lib.org
    title = title.replaceAll(RegExp(r'\b(?:libgen|z-library|annas?-archive|z-lib)(?:\.[a-z]{2,4})?\b', caseSensitive: false), '');

    // 4. Strip bracketed / parenthesized hashes, tags, and years
    title = title.replaceAll(RegExp(r'\[\s*(?:z-library|libgen|annas?-archive)[^\]]*\]', caseSensitive: false), '');
    title = title.replaceAll(RegExp(r'\(\s*(?:z-lib\.org|libgen|anna.s archive)[^\)]*\)', caseSensitive: false), '');
    title = title.replaceAll(RegExp(r'^\s*\[\d{4}\]\s*'), '');
    title = title.replaceAll(RegExp(r'\(\s*\d{4}\s*(?:,\s*[^)]*)?\)', caseSensitive: false), '');

    // 5. Strip file extensions
    title = title.replaceAll(RegExp(r'\.(?:pdf|docx|txt|epub)$', caseSensitive: false), '');

    // 6. Strip MD5 / 32-char hex hashes
    title = title.replaceAll(RegExp(r'\b[a-f0-9]{32}\b', caseSensitive: false), '');

    // 7. Strip raw repo / archive prefix tags
    title = title.replaceAll(RegExp(r'^(?:github|repo|books|archive|libgen)[_\s-]+', caseSensitive: false), '');

    // 8. Strip long ISBN / numeric hashes (e.g. _9781617298516_ or _02834891283 or 978-1-61729-851-6)
    title = title.replaceAll(RegExp(r'[_\s-]*(?:978[-_\s]?\d{9,10}|978[-_\s]?\d{1,5}[-_\s]?\d{1,7}[-_\s]?\d{1,7}[-_\s]?\d|\d{10,13})[_\s-]*'), ' ');

    // 9. Replace underscores with spaces
    title = title.replaceAll('_', ' ');

    // 10. Strip common publisher suffixes at the end
    title = title.replaceAll(RegExp(r"\s+(?:Manning|OReilly|O'Reilly(?:\s+Media)?|Packt(?:\s+Publishing)?|Springer|Wiley|Addison-Wesley|McGraw-Hill|Pearson|Apress).*$", caseSensitive: false), '');

    // 11. Strip leading/trailing punctuation dashes, colons, or whitespace
    title = title.replaceAll(RegExp(r'^[-_:\s]+|[-_:\s]+$'), '');

    // 12. Collapse excess spaces
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    return title.isNotEmpty ? title : rawName;
  }

  /// Extracts a restrictive scope phrase from query (e.g. "in terms of data storage").
  static String? extractScopePhrase(String query) => PromptBuilder.extractScopePhrase(query);

  /// Extracts the most distinctive entity (non-stopwords) from a query.
  /// Guarantees that all sub-queries are strictly anchored to the specific subject.
  static String extractCoreEntity(String query) {
    const stopWords = {
      'explain', 'in', 'detail', 'detailed', 'details', 'what', 'is', 'are', 'was', 'were',
      'the', 'a', 'an', 'overview', 'of', 'introduction', 'to', 'tell', 'me', 'about',
      'how', 'does', 'do', 'did', 'work', 'works', 'working', 'architecture', 'guide', 'brief',
      'please', 'can', 'you', 'give', 'summary', 'concept', 'concepts', 'describe', 'discuss',
      'definition', 'define', 'meaning', 'list', 'main', 'core', 'role', 'purpose',
      'workflow', 'lifecycle', 'process', 'processes', 'mechanism', 'mechanisms',
      'components', 'parts', 'elements', 'steps', 'phases', 'stages', 'complete',
      'comprehensive', 'full', 'all', 'help', 'need', 'want', 'know', 'learn', 'understand',
      'difference', 'differences', 'versus', 'vs', 'between', 'importance', 'best', 'practice',
      'practices', 'example', 'examples', 'use', 'case', 'cases', 'scenario', 'scenarios',
      'implementation', 'using', 'used', 'with', 'by', 'from', 'for', 'and', 'or', 'not',
      'accommodate', 'accomodate', 'support', 'supports', 'handle', 'handles',
      'store', 'stores', 'storing', 'processing',
      'allow', 'allows', 'contain', 'contains', 'like', 'such', 'as',
      'including', 'capable', 'capability', 'capabilities', 'able', 'ability',
      'feature', 'features', 'hold', 'holds', 'holding',
    };
    final words = query
        .replaceAll(RegExp(r'[^\w\s\-]'), ' ')
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 1)
        .toList();
    final nonStopWords = words.where((w) => !stopWords.contains(w.toLowerCase())).toList();
    if (nonStopWords.isEmpty) {
      return query.trim();
    }

    // If there are words with capitalized letters or technical acronyms (e.g. "Docker", "Jenkins", "DPDP"),
    // prioritize those over common lowercase words
    final capitalized = nonStopWords.where((w) => RegExp(r'[A-Z]').hasMatch(w)).toList();
    if (capitalized.isNotEmpty && capitalized.length < nonStopWords.length) {
      return capitalized.join(' ');
    }

    // If long phrase (> 4 words), bound to the primary subject noun phrase
    if (nonStopWords.length > 4) {
      return nonStopWords.take(4).join(' ');
    }

    return nonStopWords.join(' ');
  }

  /// Extracts two distinct subjects from a comparison query (e.g. "Difference between Data Warehouse and Data Lake").
  /// Returns a map with 'entityA' and 'entityB' if a comparison structure is detected, or null otherwise.
  static Map<String, String>? extractComparisonEntities(String query) {
    final clean = query.trim();

    // Pattern 1: "Difference(s) between <A> and <B>"
    final diffMatch = RegExp(
      r'\bdiffer(?:ence|ences)?\s+between\s+(.+?)\s+(?:and|&|vs\.?|versus)\s+(.+?)(?:\?|$|\.|\bin\b|\bregarding\b|\bwith\b|\bfocusing\b)',
      caseSensitive: false,
    ).firstMatch(clean);
    if (diffMatch != null) {
      var a = extractCoreEntity(diffMatch.group(1)!);
      var b = extractCoreEntity(diffMatch.group(2)!);
      if (a.isNotEmpty && b.isNotEmpty && a.toLowerCase() != b.toLowerCase()) {
        final bWords = b.split(RegExp(r'\s+'));
        if (bWords.length > 1 && a.split(RegExp(r'\s+')).length == 1) {
          final headNoun = bWords.sublist(1).join(' ');
          final aAdj = a.toLowerCase();
          if (const {'traditional', 'modern', 'legacy', 'cloud', 'relational', 'distributed', 'centralized', 'static', 'dynamic'}.contains(aAdj)) {
            a = '$a $headNoun';
          }
        }
        return {'entityA': a, 'entityB': b};
      }
    }

    // Pattern 2: "<A> vs <B>" or "<A> versus <B>"
    final vsMatch = RegExp(
      r'(.+?)\s+(?:\bvs\.?\b|\bversus\b)\s+(.+?)(?:\?|$|\.|\bin\b|\bregarding\b|\bwith\b|\bfocusing\b)',
      caseSensitive: false,
    ).firstMatch(clean);
    if (vsMatch != null) {
      final a = extractCoreEntity(vsMatch.group(1)!);
      final b = extractCoreEntity(vsMatch.group(2)!);
      if (a.isNotEmpty && b.isNotEmpty && a.toLowerCase() != b.toLowerCase()) {
        return {'entityA': a, 'entityB': b};
      }
    }

    // Pattern 3: "Compare <A> (and|with|to) <B>"
    final compMatch = RegExp(
      r'\bcompare\s+(.+?)\s+(?:and|with|to|vs\.?|versus)\s+(.+?)(?:\?|$|\.|\bin\b|\bregarding\b|\bwith\b|\bfocusing\b)',
      caseSensitive: false,
    ).firstMatch(clean);
    if (compMatch != null) {
      final a = extractCoreEntity(compMatch.group(1)!);
      final b = extractCoreEntity(compMatch.group(2)!);
      if (a.isNotEmpty && b.isNotEmpty && a.toLowerCase() != b.toLowerCase()) {
        return {'entityA': a, 'entityB': b};
      }
    }

    return null;
  }

  /// Builds balanced retrieval facets for comparing two distinct technologies or concepts.
  /// When a restrictive `scope` is present (e.g. "data storage"), strictly anchors all facets to that scope.
  static List<Map<String, String>> buildFacetsForComparison(
    String entityA,
    String entityB, {
    String? scope,
  }) {
    if (scope != null && scope.trim().isNotEmpty) {
      final s = scope.trim();
      return [
        {
          'label': '$entityA $s Architecture',
          'bm25Query': '$entityA $s storage structure format design scaling files',
          'rerankQuery': 'What is the architecture, design, and mechanisms of $s in $entityA?',
          'anchor': entityA,
        },
        {
          'label': '$entityB $s Architecture',
          'bm25Query': '$entityB $s storage structure format design scaling files',
          'rerankQuery': 'What is the architecture, design, and mechanisms of $s in $entityB?',
          'anchor': entityB,
        },
        {
          'label': '$entityA Format & Schema in $s',
          'bm25Query': '$entityA $s format schema files layout types compression row column',
          'rerankQuery': 'What data formats, schema enforcement, and physical layout are used for $s in $entityA?',
          'anchor': entityA,
        },
        {
          'label': '$entityB Format & Schema in $s',
          'bm25Query': '$entityB $s format schema files layout types compression row column',
          'rerankQuery': 'What data formats, schema enforcement, and physical layout are used for $s in $entityB?',
          'anchor': entityB,
        },
        {
          'label': '$s Comparison & Key Differences',
          'bm25Query': '$entityA $entityB $s difference comparison contrast storage trade-offs',
          'rerankQuery': 'What are the main differences and trade-offs between $entityA and $entityB in terms of $s?',
          'anchor': '$entityA $entityB',
        },
        {
          'label': 'Cost, Capacity & Scaling of $s',
          'bm25Query': '$entityA $entityB $s cost scaling capacity storage economics tiering',
          'rerankQuery': 'How do $entityA and $entityB differ in cost, capacity scaling, and economics for $s?',
          'anchor': '$entityA $entityB',
        },
      ];
    }

    return [
      {
        'label': '$entityA Architecture & Purpose',
        'bm25Query': '$entityA definition overview purpose architecture schema',
        'rerankQuery': 'What is $entityA, what is its architecture, schema, and purpose?',
        'anchor': entityA,
      },
      {
        'label': '$entityB Architecture & Purpose',
        'bm25Query': '$entityB definition overview purpose architecture schema',
        'rerankQuery': 'What is $entityB, what is its architecture, schema, and purpose?',
        'anchor': entityB,
      },
      {
        'label': '$entityA Architecture & Workloads',
        'bm25Query': '$entityA architecture design storage workloads processing structure',
        'rerankQuery': 'What is the architecture, design, and typical workload patterns for $entityA?',
        'anchor': entityA,
      },
      {
        'label': '$entityB Architecture & Workloads',
        'bm25Query': '$entityB architecture design storage workloads processing structure',
        'rerankQuery': 'What is the architecture, design, and typical workload patterns for $entityB?',
        'anchor': entityB,
      },
      {
        'label': 'Comparison & Key Differences',
        'bm25Query': '$entityA $entityB difference comparison contrast trade-offs architecture',
        'rerankQuery': 'What are the main differences, architectural contrasts, and trade-offs between $entityA and $entityB?',
        'anchor': '$entityA $entityB',
      },
      {
        'label': 'Cost, Scaling & Resource Architecture',
        'bm25Query': '$entityA $entityB cost scaling scale storage compute resource performance throughput latency economics',
        'rerankQuery': 'How do $entityA and $entityB differ in cost, scaling, and resource architecture (decoupled compute vs clusters)?',
        'anchor': '$entityA $entityB',
      },
    ];
  }

  /// Generates domain-agnostic facets for conceptual topic exploration.
  /// Each facet provides:
  /// - `bm25Query`: Pure keyword bag for fast, broad SQLite FTS5 candidate matching.
  /// - `rerankQuery`: Natural question for ONNX MiniLM cross-encoder scoring.
  static List<Map<String, String>> buildFacetsForTopic(String query) {
    final entity = extractCoreEntity(query);
    final isEvolutionQuery = RegExp(
      r'\b(?:evolution|history|historical|modern|future|version|versions|v\d|roadmap|migration)\b',
      caseSensitive: false,
    ).hasMatch(query);

    return [
      {
        'label': 'Definition, Core Concept & Architecture',
        'bm25Query': '$entity definition overview purpose core concept architecture foundation',
        'rerankQuery': 'What is the definition, core purpose, and fundamental architecture of $entity?',
        'anchor': entity,
      },
      {
        'label': 'Foundational Infrastructure & System Components',
        'bm25Query': '$entity infrastructure components architecture system scheduler executor worker process engine server database runtime foundation',
        'rerankQuery': 'What is the foundational infrastructure, runtime environment, and core system components of $entity?',
        'anchor': entity,
      },
      {
        'label': 'Data Formats, Schemas & Specifications',
        'bm25Query': '$entity formats specifications schema protocol data structures representation types serialization interface standards',
        'rerankQuery': 'What data formats, specifications, schemas, or protocols are used in $entity?',
        'anchor': entity,
      },
      {
        'label': 'Execution Engines & Ecosystem Interoperability',
        'bm25Query': '$entity execution processing engines tools interoperability integration ecosystem downstream pipelines workflows',
        'rerankQuery': 'How does $entity interoperate with execution and processing engines, tools, or downstream systems?',
        'anchor': entity,
      },
      {
        'label': 'Operational Limitations & Challenges',
        'bm25Query': '$entity limitations challenges bottlenecks constraints failure modes trade-offs risks governance overhead',
        'rerankQuery': 'What are the operational challenges, failure modes, trade-offs, or architectural limitations of $entity?',
        'anchor': entity,
      },
      if (isEvolutionQuery)
        {
          'label': 'Modern Evolution & Advanced Standards',
          'bm25Query': '$entity evolution modern alternatives extensions advanced patterns convergence standards next-generation',
          'rerankQuery': 'How has $entity evolved over time, and what modern patterns, standards, or advanced extensions have emerged?',
          'anchor': entity,
        }
      else
        {
          'label': 'Execution Lifecycle & Workflow Scheduling',
          'bm25Query': '$entity execution lifecycle workflow scheduling state transitions task queue dispatch poll trigger worker heartbeat run process',
          'rerankQuery': 'How does the execution lifecycle, task scheduling, workflow state transitions, and queue dispatch operate in $entity?',
          'anchor': entity,
        },
    ];
  }


  static const Set<String> _citationStopWords = {
    'the', 'a', 'an', 'in', 'on', 'at', 'to', 'for', 'of', 'with', 'by', 'and', 'or',
    'is', 'are', 'was', 'were', 'it', 'this', 'that', 'these', 'those', 'as', 'from',
    'be', 'been', 'being', 'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would',
    'can', 'could', 'should', 'each', 'all', 'into', 'which', 'who', 'its', 'their',
    'than', 'more', 'also', 'such', 'other', 'used', 'using', 'provides', 'provide',
    'allows', 'allow', 'well', 'both', 'between', 'through', 'whereas', 'while',
    'include', 'includes', 'including', 'compared', 'versus'
  };

  static String _stemWord(String word) {
    var w = word.toLowerCase();
    if (w.length <= 3) return w;
    if (w.endsWith('ations') && w.length > 7) return w.substring(0, w.length - 6);
    if (w.endsWith('ation') && w.length > 6) return w.substring(0, w.length - 5);
    if (w.endsWith('ating') && w.length > 6) return w.substring(0, w.length - 5);
    if (w.endsWith('ated') && w.length > 5) return w.substring(0, w.length - 4);
    if (w.endsWith('ates') && w.length > 5) return w.substring(0, w.length - 4);
    if (w.endsWith('ate') && w.length > 4) return w.substring(0, w.length - 3);
    if (w.endsWith('ing') && w.length > 5) return w.substring(0, w.length - 3);
    if (w.endsWith('tion') && w.length > 5) return w.substring(0, w.length - 4);
    if (w.endsWith('tions') && w.length > 6) return w.substring(0, w.length - 5);
    if (w.endsWith('ment') && w.length > 5) return w.substring(0, w.length - 4);
    if (w.endsWith('ments') && w.length > 6) return w.substring(0, w.length - 5);
    if (w.endsWith('ies') && w.length > 4) return '${w.substring(0, w.length - 3)}y';
    if (w.endsWith('es') && w.length > 4) return w.substring(0, w.length - 2);
    if (w.endsWith('ed') && w.length > 4) return w.substring(0, w.length - 2);
    if (w.endsWith('ly') && w.length > 4) return w.substring(0, w.length - 2);
    if (w.endsWith('able') && w.length > 5) return w.substring(0, w.length - 4);
    if (w.endsWith('ive') && w.length > 5) return w.substring(0, w.length - 3);
    if (w.endsWith('s') && !w.endsWith('ss') && w.length > 3) return w.substring(0, w.length - 1);
    return w;
  }

  /// Removes internal phrase repetitions within a sentence (e.g. circular definitions).
  static String _cleanInternalRepetition(String sentence) {
    var words = sentence.split(RegExp(r'\s+'));
    if (words.length < 8) return sentence;
    for (int n = 6; n >= 3; n--) {
      for (int i = 0; i <= words.length - 2 * n; i++) {
        final pWords = words.sublist(i, i + n);
        final phrase = pWords.join(' ').toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '');
        for (int j = i + n; j <= words.length - n; j++) {
          final tWords = words.sublist(j, j + n);
          final target = tWords.join(' ').toLowerCase().replaceAll(RegExp(r'[^\w\s]'), '');
          if (phrase == target && phrase.length > 8) {
            int removeStart = j;
            if (removeStart > 0 && const {'by', 'for', 'and', 'through', 'via', 'with'}.contains(words[removeStart - 1].toLowerCase())) {
              removeStart--;
            }
            final before = words.sublist(0, removeStart);
            final after = words.sublist(j + n);
            final cleaned = [...before, ...after].join(' ');
            return _cleanInternalRepetition(
              cleaned.replaceAll(RegExp(r'\s*,\s*,+'), ',').replaceAll(RegExp(r'\s{2,}'), ' ').trim(),
            );
          }
        }
      }
    }
    return sentence;
  }

  static Set<String> _extractContentWords(String s) {
    // Strip XML tags (<...>), inline math expressions ($...$), and code ticks so syntax doesn't distort lexical matching
    final textNoMath = s
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\$[^$\n]+\$'), ' ')
        .replaceAll(RegExp(r'`[^`\n]+`'), ' ');
    return textNoMath
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s\-]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.length > 2 && !_citationStopWords.contains(w))
        .map(_stemWord)
        .toSet();
  }

  /// Checks sentences containing causal words ("due to", "because", etc.) against the cited chunk words.
  /// If the causal reasoning clause lacks evidence overlap with the cited chunks, drops the ungrounded clause.
  static String checkAndCleanUngroundedCausation(
    String sentence,
    List<Set<String>> citedChunkWordSets,
  ) {
    if (citedChunkWordSets.isEmpty) return sentence;

    final causalRegex = RegExp(
      r'([,\s]+)\b(?:due\s+to|owing\s+to|as\s+a\s+result\s+of|because\s+(?:of\s+)?)\s+([^,.;\[\]]+)',
      caseSensitive: false,
    );

    final match = causalRegex.firstMatch(sentence);
    if (match == null) return sentence;

    final reasonText = match.group(2)!.trim();
    final reasonWords = _extractContentWords(reasonText);
    if (reasonWords.isEmpty) return sentence;

    // Check overlap of the reason words against all cited chunks
    int maxMatches = 0;
    for (final cWords in citedChunkWordSets) {
      final matches = reasonWords.intersection(cWords).length;
      if (matches > maxMatches) {
        maxMatches = matches;
      }
    }

    final minNeeded = reasonWords.length <= 2 ? 1 : 2;
    if (maxMatches < minNeeded) {
      print('[DROP UNGROUNDED CAUSATION] In "$sentence": reason "$reasonText" lacked evidence (matches=$maxMatches, needed=$minNeeded)');
      var cleaned = sentence.replaceRange(match.start, match.end, '');
      cleaned = cleaned.replaceAllMapped(RegExp(r'(\w)\['), (m) => '${m[1]} [');
      cleaned = cleaned.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
      return cleaned;
    }

    return sentence;
  }

  /// Post-processes generated response:
  /// 1. Strips model-generated citations and assigns deterministic citations via word overlap against rawChunks.
  /// 2. Drops sentences that fail overlap threshold (unsupported claims / hallucinated rationales).
  /// 3. Drops near-duplicate sentences across the response.
  /// 4. Completely removes filler "Technical Terms" / "Glossary" sections.
  /// 5. Exempts valid Markdown tables and LaTeX math blocks from lexical deletion.
  /// 6. Cleans up orphaned or empty headings.
  static String enforceCitationsAndCleanOutput(
    String text, {
    List<String>? rawChunks,
    AnswerUseCase? useCase,
  }) {
    if (text.trim().isEmpty) return text;
    if (text.startsWith("This topic is not covered in your books")) return text;

    final headingRegex = RegExp(r'^(#{1,4})\s+(.+)$');
    final bannedHeadingRegex = RegExp(
      r'^(?:technical terms|key terms|glossary|technical concepts|key concepts|takeaway|conclusion|summary takeaway)\b', 
      caseSensitive: false,
    );
    final exemptHeadingRegex = RegExp(
      r'^(?:important concepts not covered|dimensions not covered|not covered|coverage limitations|uncovered|missing concepts)\b',
      caseSensitive: false,
    );
    final definitionHeadingRegex = RegExp(
      r'^(?:definition|overview)\b',
      caseSensitive: false,
    );
    final bulletRegex = RegExp(r'^(\s*(?:[-*+]|\d+\.)\s+)(.+)$');

    // Precompute chunk content words for lexical matching
    final chunkWordSets = (rawChunks ?? [])
        .map((c) => _extractContentWords(c))
        .toList();

    final lines = text.split('\n');
    final cleanedLines = <String>[];
    final seenSentenceWordSets = <Set<String>>[];
    final seenDefinitionWordSets = <Set<String>>[];
    final seenBoldTerms = <String>{};
    bool inBannedSection = false;
    bool inExemptSection = false;
    bool inDefinitionSection = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final trimmed = line.trim();

      if (trimmed.isEmpty) {
        if (!inBannedSection && cleanedLines.isNotEmpty && cleanedLines.last.isNotEmpty) {
          cleanedLines.add('');
        }
        continue;
      }

      // Check for markdown headings
      final headingMatch = headingRegex.firstMatch(trimmed);
      if (headingMatch != null) {
        final headingTitle = headingMatch.group(2)!.trim();
        if (bannedHeadingRegex.hasMatch(headingTitle)) {
          inBannedSection = true;
          inExemptSection = false;
          inDefinitionSection = false;
          continue;
        } else if (exemptHeadingRegex.hasMatch(headingTitle)) {
          inBannedSection = false;
          inExemptSection = true;
          inDefinitionSection = false;
          cleanedLines.add(trimmed);
          continue;
        } else if (definitionHeadingRegex.hasMatch(headingTitle)) {
          inBannedSection = false;
          inExemptSection = false;
          inDefinitionSection = true;
          cleanedLines.add(trimmed);
          continue;
        } else {
          // If in comparison mode, only allow Overview and Key Differences
          if (useCase == AnswerUseCase.comparison) {
            final isAllowedComparison = RegExp(
              r'^(?:overview|key\s+differences|differences|key\s+comparison|comparison)\b',
              caseSensitive: false,
            ).hasMatch(headingTitle);
            if (!isAllowedComparison) {
              inBannedSection = false;
              inExemptSection = false;
              inDefinitionSection = false;
              continue; // Drop invented off-scope headings in comparison mode
            }
          }
          inBannedSection = false;
          inExemptSection = false;
          inDefinitionSection = false;
          cleanedLines.add(trimmed);
          continue;
        }
      }

      if (inBannedSection) continue;

      // EXEMPTION 0: Coverage disclaimers and explicit "not covered" statements
      if (inExemptSection || RegExp(r'^(?:the uploaded books? (?:do|does) not cover|the available evidence does not establish|note on textbook coverage)\b', caseSensitive: false).hasMatch(trimmed)) {
        cleanedLines.add(line);
        continue;
      }

      // EXEMPTION 1: Math equations, formulas, and Markdown tables (via AnswerSanitizer.isMathOrTableLine)
      if (AnswerSanitizer.isMathOrTableLine(trimmed)) {
        cleanedLines.add(line);
        continue;
      }

      // EXEMPTION 2: Code block fences
      if (trimmed.startsWith('```')) {
        cleanedLines.add(line);
        continue;
      }

      String prefix = '';
      String rawContent = trimmed;

      final bulletMatch = bulletRegex.firstMatch(trimmed);
      if (bulletMatch != null) {
        prefix = bulletMatch.group(1)!;
        rawContent = bulletMatch.group(2)!;
      }

      // If this is a bullet point, extract the bold key term to prevent duplicate terms
      String? boldTermKey;
      if (prefix.isNotEmpty) {
        final boldMatch = RegExp(r'\*\*([^*]+)\*\*').firstMatch(rawContent);
        if (boldMatch != null) {
          final rawTerm = boldMatch.group(1)!.trim().toLowerCase();
          final termWords = _extractContentWords(rawTerm);
          if (termWords.isNotEmpty) {
            boldTermKey = termWords.join('_');
            if (seenBoldTerms.contains(boldTermKey)) {
              print('[DEDUPE DROP REPEATED TERM] "$rawContent" (bold term "$rawTerm" already defined)');
              continue;
            }
          }
        }

        // Substantive body check: a bullet MUST contain meaningful explanatory body text beyond the bold label
        final strippedOfBold = rawContent.replaceFirst(RegExp(r'^\*\*[^*]+\*\*[:\-]?\s*'), '').trim();
        final bodyWordsWithoutCites = _extractContentWords(
          strippedOfBold.replaceAll(RegExp(r'\[\s*(?:\d+|[a-zA-Z])+(?:\s*,\s*(?:\d+|[a-zA-Z])+)*\s*\]'), '').trim()
        );
        if (bodyWordsWithoutCites.length < 3) {
          print('[REJECT EMPTY BULLET] "$trimmed" (insufficient body content: ${bodyWordsWithoutCites.length} words)');
          continue;
        }
      }

      // Split into sentences while preserving original citations for verification
      final rawSentences = rawContent
          .split(RegExp(r'(?<=[.!?])\s+'))
          .where((s) => s.trim().length > 6)
          .toList();

      final acceptedSentences = <String>[];

      for (final rawSentence in rawSentences) {
        // Extract any citations the model provided for this specific sentence
        final modelCites = RegExp(r'\[(\d+)\]')
            .allMatches(rawSentence)
            .map((m) => int.parse(m.group(1)!))
            .where((k) => k >= 1 && k <= chunkWordSets.length)
            .toSet()
            .toList();

        var cleanedSentence = _cleanInternalRepetition(rawSentence);
        cleanedSentence = AnswerSanitizer.correctSchemaOverstatements(cleanedSentence);
        cleanedSentence = AnswerSanitizer.correctTechnicalContradictions(cleanedSentence);
        cleanedSentence = AnswerSanitizer.sanitizeInformalTropes(cleanedSentence);

        final cleanSentenceText = cleanedSentence
            .replaceAll(RegExp(r'\[\s*(?:\d+|[a-zA-Z])+(?:\s*,\s*(?:\d+|[a-zA-Z])+)*\s*\]'), '')
            .trim()
            .replaceAll(RegExp(r'[.\s]+$'), '');

        if (cleanSentenceText.isEmpty) continue;

        // Never attach citations to lead-in clauses ending in a colon (e.g., "Key differences include:")
        final isLeadInClause = cleanSentenceText.endsWith(':') ||
            RegExp(r':\s*$', caseSensitive: false).hasMatch(cleanedSentence.trim());

        if (isLeadInClause) {
          acceptedSentences.add(cleanSentenceText);
          continue;
        }

        // Strip bold label from bullet text when computing comparison words for deduplication
        final bodySentence = cleanSentenceText
            .replaceFirst(RegExp(r'^\*\*[^*]+\*\*[:\-]?\s*'), '')
            .trim();
        final compareWords = _extractContentWords(bodySentence.isNotEmpty ? bodySentence : cleanSentenceText);
        final sWords = _extractContentWords(cleanSentenceText);
        if (compareWords.length < 2) continue;

        // Check for near-duplicate of an already included sentence or definition
        bool isDuplicate = false;
        for (final seen in seenSentenceWordSets) {
          final inter = compareWords.intersection(seen).length;
          final union = compareWords.union(seen).length;
          final jaccard = union == 0 ? 0.0 : inter / union;
          final minLen = math.min(compareWords.length, seen.length);
          final containment = minLen == 0 ? 0.0 : inter / minLen;

          // If this sentence is a bullet with a unique bold term, and we are comparing against
          // a definition sentence, allow it if it introduces substantive novel content words
          // (e.g. comparing dimensions) rather than simply parroting the definition.
          final isDefinitionSentence = seenDefinitionWordSets.contains(seen);
          if (boldTermKey != null && isDefinitionSentence) {
            final novelWords = compareWords.difference(seen).length;
            if (novelWords >= 3 && jaccard < 0.60) {
              continue;
            }
          }

          // Stricter deduplication threshold (0.40 / 0.45) for short bullets/sentences (<= 12 words)
          // to catch reworded claims, stem variations, or padded repetitions.
          final isShort = compareWords.length <= 12;
          final jaccardThreshold = isShort ? 0.40 : 0.50;
          final containmentThreshold = isShort ? 0.45 : 0.50;
          final minInter = isShort ? 3 : 4;

          if (jaccard >= jaccardThreshold || (inter >= minInter && containment >= containmentThreshold)) {
            isDuplicate = true;
            print('[DEDUPE DROP] "$cleanSentenceText" (inter=$inter, jaccard=${jaccard.toStringAsFixed(2)}, containment=${containment.toStringAsFixed(2)})');
            break;
          }
        }
        if (isDuplicate) continue;

        // Deterministic Chunk Matching & Evidence Grounding Verification
        if (chunkWordSets.isNotEmpty) {
          final chunkMatches = <int, int>{};
          final chunkRecalls = <int, double>{};
          int bestChunkIdx = -1;
          int bestMatchCount = 0;
          double bestRecall = 0.0;

          for (int cIdx = 0; cIdx < chunkWordSets.length; cIdx++) {
            final cWords = chunkWordSets[cIdx];
            final matches = sWords.intersection(cWords).length;
            final recall = sWords.isNotEmpty ? matches / sWords.length : 0.0;
            chunkMatches[cIdx] = matches;
            chunkRecalls[cIdx] = recall;

            if (matches > bestMatchCount || (matches == bestMatchCount && recall > bestRecall)) {
              bestMatchCount = matches;
              bestRecall = recall;
              bestChunkIdx = cIdx;
            }
          }

          // Evidence Grounding Filter:
          // A sentence in Key Points MUST have direct evidence in at least one chunk.
          // Drop completely unsupported / hallucinated claims that lack evidence overlap.
          final minMatchesNeeded = sWords.length <= 4 ? 1 : 2;
          final isGrounded = bestMatchCount >= minMatchesNeeded &&
              (sWords.length < 6 || bestRecall >= 0.15 || bestMatchCount >= 3);

          if (!inDefinitionSection && !isGrounded) {
            print('[VERIFIER DROP UNGROUNDED] "$cleanSentenceText" (bestMatches=$bestMatchCount, bestRecall=${bestRecall.toStringAsFixed(2)}, sWords=${sWords.length})');
            continue;
          }

          // Verify model-provided citations: keep only if supported and competitive with bestChunk
          final verifiedChunks = <int>{};
          for (final cite in modelCites) {
            final cIdx = cite - 1;
            final mCount = chunkMatches[cIdx] ?? 0;
            final mRecall = chunkRecalls[cIdx] ?? 0.0;
            if (mCount >= minMatchesNeeded && (mCount >= bestMatchCount - 1 || mRecall >= 0.25)) {
              verifiedChunks.add(cIdx);
            }
          }

          // If model citations were inaccurate, missing, or hallucinated, use the best evidence chunk
          if (verifiedChunks.isEmpty && bestChunkIdx != -1) {
            verifiedChunks.add(bestChunkIdx);
          }

          // Multi-chunk citation support (e.g. comparison claims drawing facts from 2 different excerpts)
          if (verifiedChunks.length == 1 && chunkWordSets.length > 1) {
            final primaryIdx = verifiedChunks.first;
            final primaryMatchedWords = sWords.intersection(chunkWordSets[primaryIdx]);

            for (int cIdx = 0; cIdx < chunkWordSets.length; cIdx++) {
              if (cIdx == primaryIdx) continue;
              final novelMatches = sWords.intersection(chunkWordSets[cIdx]).difference(primaryMatchedWords);
              final totalMatches = chunkMatches[cIdx] ?? 0;
              final recall = chunkRecalls[cIdx] ?? 0.0;
              // Second chunk must contribute >= 2 novel distinct matching words and have substantive overlap
              if (novelMatches.length >= 2 && totalMatches >= 3 && (recall >= 0.20 || modelCites.contains(cIdx + 1))) {
                verifiedChunks.add(cIdx);
                break; // Cap at 2 supporting excerpts for readable, clean citations [1, 2]
              }
            }
          }

          // Clean ungrounded causal clauses ("due to", "because") if cited chunks lack evidence
          final citedChunkWordSets = verifiedChunks.map((idx) => chunkWordSets[idx]).toList();
          final causallyCleaned = checkAndCleanUngroundedCausation(cleanSentenceText, citedChunkWordSets);

          final sortedCiteList = (verifiedChunks.map((idx) => idx + 1).toList()..sort());
          final citeString = sortedCiteList.isNotEmpty
              ? '[${sortedCiteList.join(", ")}]'
              : '[1]';

          final cited = '$causallyCleaned $citeString.';
          acceptedSentences.add(cited);
          seenSentenceWordSets.add(compareWords);
          if (inDefinitionSection) {
            seenDefinitionWordSets.add(compareWords);
            print('[VERIFIER DEFINITION] "$causallyCleaned" -> $citeString (matches=$bestMatchCount, recall=${bestRecall.toStringAsFixed(2)})');
          } else {
            print('[VERIFIER PRESERVE] "$causallyCleaned" -> $citeString');
          }
        } else {
          acceptedSentences.add('$cleanSentenceText.');
        }
      }

      if (acceptedSentences.isNotEmpty) {
        if (boldTermKey != null) {
          seenBoldTerms.add(boldTermKey);
        }
        if (prefix.isNotEmpty) {
          cleanedLines.add('$prefix${acceptedSentences.join(" ")}');
        } else {
          cleanedLines.add(acceptedSentences.join(" "));
        }
      }
    }

    // Clean up orphaned headings
    final finalLines = <String>[];
    for (int i = 0; i < cleanedLines.length; i++) {
      final line = cleanedLines[i];
      if (headingRegex.hasMatch(line)) {
        bool hasContent = false;
        for (int j = i + 1; j < cleanedLines.length; j++) {
          final next = cleanedLines[j].trim();
          if (headingRegex.hasMatch(next)) break;
          if (next.isNotEmpty) {
            hasContent = true;
            break;
          }
        }
        if (hasContent) {
          finalLines.add(line);
        }
      } else {
        finalLines.add(line);
      }
    }

    final result = finalLines.join('\n').trim();
    return result.isNotEmpty 
        ? result 
        : 'This topic has limited direct coverage in your uploaded books. No verified claims could be established from the retrieved excerpts.';
  }

  /// Builds relevant passages for UI display and audit trail.
  /// Instead of showing static introductory snippet prefixes, it locates the specific
  /// sentence or 1-2 sentence window in each retrieved chunk that has the highest
  /// lexical overlap with the claim(s) in responseText that cite this chunk.
  static List<Map<String, String>> buildBestMatchingPassages({
    required List<Map<String, dynamic>> allResults,
    required String responseText,
    required String query,
  }) {
    final passages = <Map<String, String>>[];
    if (allResults.isEmpty) return passages;

    // Split response into sentences
    final responseSentences = responseText
        .split(RegExp(r'(?<=[.!?])\s+'))
        .where((s) => s.trim().length > 6)
        .toList();

    for (int i = 0; i < allResults.length; i++) {
      final result = allResults[i];
      final content = result['content'] as String? ?? '';
      if (content.trim().isEmpty) continue;

      final metadata = result['metadata'] as Map<String, dynamic>? ?? {};
      final rawYear = metadata['publication_year'];
      final hasValidYear = rawYear != null &&
          rawYear.toString() != '0000' &&
          rawYear.toString() != 'Unknown Year' &&
          int.tryParse(rawYear.toString()) != null &&
          int.parse(rawYear.toString()) > 1990;
      final yearDisplay = hasValidYear ? rawYear.toString() : 'N/A';
      final rawFilename = metadata['virtual_filename'] ?? metadata['filename'] ?? 'unknown';
      final cleanTitle = formatCleanBookTitle(rawFilename.toString());
      final facetLabel = result['facet_label'] as String? ?? 'General';

      final citationIndex = i + 1;
      final citePattern = RegExp(
        r'\[\s*(?:\d+\s*,\s*)*' + '$citationIndex' + r'(?:\s*,\s*\d+)*\s*\]',
      );

      // Find all sentences in responseText that cite this chunk [citationIndex]
      final citingSentences = responseSentences.where((s) => citePattern.hasMatch(s)).toList();

      // Collect target words for matching:
      // If citing sentences exist, match against their content words.
      // Otherwise, match against the query/coreEntity words.
      Set<String> targetWords;
      if (citingSentences.isNotEmpty) {
        targetWords = _extractContentWords(citingSentences.join(' '));
      } else {
        targetWords = _extractContentWords(query);
      }

      // Split chunk content into candidate sentences
      final rawChunkSentences = content
          .replaceAll(RegExp(r'\s+'), ' ')
          .split(RegExp(r'(?<=[.!?])\s+'))
          .map((s) => s.trim())
          .where((s) => s.length > 15)
          .toList();

      String bestText = '';
      if (rawChunkSentences.isNotEmpty && targetWords.isNotEmpty) {
        int highestOverlap = -1;
        int bestIdx = 0;

        for (int sIdx = 0; sIdx < rawChunkSentences.length; sIdx++) {
          final sWords = _extractContentWords(rawChunkSentences[sIdx]);
          final overlap = sWords.intersection(targetWords).length;
          if (overlap > highestOverlap) {
            highestOverlap = overlap;
            bestIdx = sIdx;
          }
        }

        // Take the best sentence. If it's short (< 120 chars) and there's a next sentence, combine them
        final primarySentence = rawChunkSentences[bestIdx];
        if (primarySentence.length < 120 && bestIdx + 1 < rawChunkSentences.length) {
          bestText = '$primarySentence ${rawChunkSentences[bestIdx + 1]}';
        } else {
          bestText = primarySentence;
        }

        // Cap to reasonable length (e.g. 500 chars) with clean word boundary
        if (bestText.length > 500) {
          final cutoff = bestText.lastIndexOf(' ', 500);
          bestText = '${bestText.substring(0, cutoff > 300 ? cutoff : 500).trim()}...';
        }
      }

      // If no good match was found or chunk had no sentences, use fallback snippet
      if (bestText.trim().isEmpty) {
        bestText = _formatFallbackSnippet(content, query, maxLen: 500);
      }

      passages.add({
        'index': '$citationIndex',
        'book': cleanTitle,
        'year': yearDisplay,
        'facet': facetLabel,
        'text': bestText,
      });
    }

    return passages;
  }

  static String _formatFallbackSnippet(String text, String entity, {int maxLen = 500}) {
    final clean = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.length <= maxLen) return clean;

    final entityLower = entity.toLowerCase();
    final cleanLower = clean.toLowerCase();
    final entityIdx = cleanLower.indexOf(entityLower);

    if (entityIdx > 200 && entityIdx < clean.length - 50) {
      final start = clean.lastIndexOf(' ', math.max(0, entityIdx - 80));
      final safeStart = start != -1 ? start + 1 : math.max(0, entityIdx - 80);
      final end = clean.indexOf(' ', math.min(clean.length - 1, safeStart + maxLen));
      final safeEnd = end != -1 ? end : math.min(clean.length, safeStart + maxLen);
      return '...${clean.substring(safeStart, safeEnd).trim()}...';
    }

    final truncated = clean.substring(0, maxLen);
    final lastSpace = truncated.lastIndexOf(' ');
    return '${(lastSpace > 350 ? truncated.substring(0, lastSpace) : truncated).trim()}...';
  }

  /// Generates suggested follow-up questions grounded in unused high-scoring candidates
  /// from the user's library. Guarantees that suggested questions are answerable.
  static List<String> _generateFollowUpQuestions(
    String query,
    String coreEntity,
    List<Map<String, dynamic>> unusedCandidates,
  ) {
    final questions = <String>[];
    final seenLabels = <String>{};

    for (final candidate in unusedCandidates) {
      final label = candidate['facet_label'] as String? ?? '';
      if (label.isEmpty || seenLabels.contains(label)) continue;
      seenLabels.add(label);

      switch (label) {
        case 'Examples & Use Cases':
          questions.add('What are practical real-world examples and use cases of $coreEntity?');
          break;
        case 'Mechanisms & How It Works':
          questions.add('How does $coreEntity work internally under the hood?');
          break;
        case 'Limitations & Trade-offs':
          questions.add('What are the key limitations and trade-offs of $coreEntity?');
          break;
        case 'Workflow & Lifecycle':
          questions.add('What is the complete lifecycle or workflow of $coreEntity?');
          break;
        case 'Key Components & Elements':
          questions.add('What are the core components and architecture of $coreEntity?');
          break;
        default:
          final q = candidate['facet_query'] as String?;
          if (q != null && q.isNotEmpty && q != query) {
            questions.add(q);
          }
      }

      if (questions.length >= 3) break;
    }

    // Grounded fallbacks if fewer than 2 candidates had distinct facet labels
    if (questions.length < 2) {
      if (!seenLabels.contains('Examples & Use Cases')) {
        questions.add('What are practical applications and examples of $coreEntity?');
      }
      if (!seenLabels.contains('Limitations & Trade-offs')) {
        questions.add('What are the main limitations and challenges of $coreEntity?');
      }
    }

    return questions.take(3).toList();
  }
}

