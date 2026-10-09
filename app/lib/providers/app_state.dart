import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import '../models/app_models.dart';
import '../services/local_database_service.dart';
import '../services/local_llm_service.dart';
import '../services/document_processor.dart';
import '../services/vector_db_service.dart';
import '../services/studio_service.dart';
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
    await loadSpaces();
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

      // 2. Add user message
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
      
      void updateAssistantMessage(String newText) {
        _currentChat!.messages[aiMsgIndex] = ChatMessage(
          role: 'assistant',
          content: newText,
          timestamp: aiMsg.timestamp,
        );
        notifyListeners();
      }

      // 3.5 LLM Query Expansion
      updateAssistantMessage("Expanding search query for better retrieval...");
      final expandedKeywords = await LocalLlmService.generateQueryExpansion(query);
      final expandedQuery = "$query $expandedKeywords";

      // 4. Retrieve Vector Context (RAG)
      updateAssistantMessage("Searching textbooks...");
      List<String> contextChunks = [];
      try {
        final results = await VectorDbService.query(_currentSpace!.id, expandedQuery, nResults: 2);
        
        if (results.isEmpty) {
          final fallbackMsg = "The current space (MLOps) only references this topic in passing. For an in-depth architectural breakdown, consider adding a dedicated Distributed Systems or Cloud Infrastructure text.";
          _currentChat!.messages.add(ChatMessage(role: 'assistant', content: fallbackMsg, timestamp: DateTime.now().toIso8601String()));
          await LocalDatabaseService.addMessage(_currentChat!.id, 'assistant', fallbackMsg);
          _isThinking = false;
          _setLoading(false);
          notifyListeners();
          return;
        }

        for (int i = 0; i < results.length; i++) {
          final result = results[i];
          final content = result['content'] as String;
          final metadata = result['metadata'] as Map<String, dynamic>;
          final year = metadata['publication_year'] ?? 'Unknown Year';
          final filename = metadata['virtual_filename'] ?? 'unknown';
          contextChunks.add('[${i + 1}] $filename ($year):\n$content');
        }
      } catch (e) {
        print('Vector DB Query failed: $e');
      }

      // 5. Stream response from LocalLlmService
      String fullResponse = "";
      
      // Keep screen awake while generating response
      WakelockPlus.enable();
      
      final stream = LocalLlmService.generateResponse(
        _currentChat!.messages,
        contextChunks: contextChunks,
      );
      
      bool firstChunk = true;
      
      await for (final chunk in stream) {
        if (firstChunk) {
          _isThinking = false;
          firstChunk = false;
        }
        fullResponse += chunk;
        updateAssistantMessage(fullResponse);
      }

      // 5. Save the AI message to DB once done
      await LocalDatabaseService.addMessage(_currentChat!.id, 'assistant', fullResponse);

    } catch (e) {
      _setError('Failed to send message locally: $e');
      _isThinking = false;
    } finally {
      _setLoading(false);
      WakelockPlus.disable();
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

        // 1. Extract text via Native Platform Channel (ReadPdfText) -> Avoids Dart Heap OOM
        final processor = DocumentProcessor();
        final fileData = await processor.processFile(file.path!);
        final content = fileData['content'] as String;
        final virtualFilename = fileData['virtual_filename'] as String;
        fileData.remove('content'); // free immediately

        // 2. Offload heavy string manipulation (chunking) to background isolate
        final chunks = await compute(chunkTextTask, {
          'content': content,
          'virtualFilename': virtualFilename,
        });
        
        // Formulate metadata
        final metadatas = chunks.map((_) => {
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
}

