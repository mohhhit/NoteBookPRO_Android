import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/studio_models.dart';
import 'api_service.dart';
import 'local_database_service.dart';
import 'pdf_export_service.dart';

class PdfDownloadResult {
  final Uint8List bytes;
  final String filename;

  PdfDownloadResult({required this.bytes, required this.filename});
}

class StudioService {
  static Map<String, String> _headers(String baseUrl, {bool json = false}) {
    return ApiService.buildHeaders(
      baseUrl: baseUrl,
      extra: json ? {'Content-Type': 'application/json'} : null,
    );
  }

  static Never _throwHttpError(String operation, http.Response response) {
    throw Exception(
      ApiService.formatHttpError(operation: operation, response: response),
    );
  }

  // =========================================================================
  // NOTEBOOK METHODS (Local SQLite On-Device)
  // =========================================================================

  static String deriveTitleFromQuestion(String question) {
    var q = question.trim().replaceAll(RegExp(r'^[#*_\-\s]+'), '');
    final firstLine = q.split('\n').first.trim();
    if (firstLine.isNotEmpty) q = firstLine;
    if (q.length > 60) {
      return '${q.substring(0, 57).trim()}...';
    }
    return q.isNotEmpty ? q : 'Notebook Entry';
  }

  /// Extracts the main answer text, dropping any trailing "### Relevant Passages" section.
  static String extractMainAnswerContent(String rawContent) {
    if (rawContent.isEmpty) return '';
    final passageRegex = RegExp(
      r'(?:\r?\n\s*---\s*)?\r?\n#{2,4}\s*Relevant Passages:?\s*',
      caseSensitive: false,
    );
    final match = passageRegex.firstMatch(rawContent);
    if (match != null) {
      return rawContent.substring(0, match.start).trim();
    }
    final altRegex = RegExp(
      r'^#{2,4}\s*Relevant Passages:?\s*',
      caseSensitive: false,
    );
    final altMatch = altRegex.firstMatch(rawContent);
    if (altMatch != null) {
      return '';
    }
    return rawContent.trim();
  }

  /// Strips inline citation markers like [1], [1, 2], (Document 1), **[1]**, [10]
  static String stripInlineDocumentReferences(String text) {
    final docRefs = RegExp(
      r'\s*\((?:Document\s+\d+)(?:\s*,\s*Document\s+\d+)*\)',
      caseSensitive: false,
    );
    final bracketRefs = RegExp(
      r'\s*(?:\*\*)?\[\d+(?:\s*,\s*\d+)*\](?:\*\*)?',
      caseSensitive: false,
    );
    String stripped = text.replaceAll(docRefs, '').replaceAll(bracketRefs, '');
    final compactSpaces = stripped.replaceAll(RegExp(r' {2,}'), ' ');
    return compactSpaces.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Converts LaTeX math expressions into clean Unicode / readable plain text.
  static String normalizeMathForDisplay(String text) {
    var out = text;
    out = out.replaceAll(r'\$', r'$');
    out = out.replaceAll('\\\\', '\\');

    // Replace block and inline math markers
    out = out.replaceAllMapped(
      RegExp(r'\$\$([\s\S]+?)\$\$'),
      (m) => _latexExpressionToPlainText((m.group(1) ?? '').trim()),
    );
    out = out.replaceAllMapped(
      RegExp(r'\\\[([\s\S]+?)\\\]'),
      (m) => _latexExpressionToPlainText((m.group(1) ?? '').trim()),
    );
    out = out.replaceAllMapped(
      RegExp(r'\\\(([\s\S]+?)\\\)'),
      (m) => _latexExpressionToPlainText((m.group(1) ?? '').trim()),
    );
    out = out.replaceAllMapped(
      RegExp(r'\$(?!\$)([\s\S]+?)\$(?!\$)'),
      (m) => _latexExpressionToPlainText((m.group(1) ?? '').trim()),
    );
    return out;
  }

  static String _latexExpressionToPlainText(String expr) {
    var out = expr;
    const replacements = {
      r'\times': '×',
      r'\cdot': '·',
      r'\pm': '±',
      r'\leq': '≤',
      r'\geq': '≥',
      r'\neq': '≠',
      r'\approx': '≈',
      r'\infty': '∞',
      r'\sum': '∑',
      r'\prod': '∏',
      r'\sqrt': '√',
      r'\alpha': 'α',
      r'\beta': 'β',
      r'\gamma': 'γ',
      r'\delta': 'δ',
      r'\theta': 'θ',
      r'\lambda': 'λ',
      r'\mu': 'μ',
      r'\sigma': 'σ',
      r'\pi': 'π',
      r'\rightarrow': '→',
      r'\leftarrow': '←',
      r'\Rightarrow': '⇒',
      r'\Leftarrow': '⇐',
      r'\log': 'log',
      r'\ln': 'ln',
      r'\%': '%',
    };
    replacements.forEach((key, value) {
      out = out.replaceAll(key, value);
    });
    out = out.replaceAll('{', '').replaceAll('}', '');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  /// Ensures blank lines precede and follow list blocks (matching OG backend's _normalize_markdown_lists).
  static String normalizeMarkdownLists(String text) {
    if (text.isEmpty) return '';
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final out = <String>[];
    bool inList = false;
    final listMarker = RegExp(r'^(\s*(?:[-*+•]|\d+[.)]))\s+');

    for (final line in lines) {
      final isListItem = listMarker.hasMatch(line);
      if (isListItem && !inList) {
        if (out.isNotEmpty && out.last.trim().isNotEmpty) {
          out.add('');
        }
        inList = true;
      } else if (!isListItem && inList) {
        if (line.trim().isNotEmpty && out.isNotEmpty && out.last.trim().isNotEmpty) {
          out.add('');
        }
        inList = false;
      } else if (line.trim().isEmpty) {
        inList = false;
      }
      out.add(line);
    }
    return out.join('\n');
  }

  /// Master formatter: Transforms raw assistant chat content into clean, professional note/export markdown.
  static String formatChatAnswer(String rawContent) {
    if (rawContent.isEmpty) return '';
    final mainText = extractMainAnswerContent(rawContent);
    final stripped = stripInlineDocumentReferences(mainText);
    final mathNormalized = normalizeMathForDisplay(stripped);
    final listNormalized = normalizeMarkdownLists(mathNormalized);
    return listNormalized.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Extracts question and answer from a Q/A formatted block.
  static Map<String, String>? extractChatQa(String text) {
    if (text.isEmpty) return null;
    final match = RegExp(
      r'^\s*Q:\s*(.*?)\s*\n\s*\n\s*A:\s*(.*)$',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    final q = (match.group(1) ?? '').trim();
    final a = (match.group(2) ?? '').trim();
    if (q.isEmpty || a.isEmpty) return null;
    return {'question': q, 'answer': a};
  }

  static Future<NotebookEntry> createNotebookEntry({
    required String spaceId,
    required String title,
    required String content,
    String sourceType = 'manual',
    String? sourceId,
    List<String>? tags,
  }) async {
    return await LocalDatabaseService.createNotebookEntry(
      spaceId: spaceId,
      title: title,
      content: content,
      sourceType: sourceType,
      sourceId: sourceId,
      tags: tags,
    );
  }

  static Future<NotebookEntry> addChatToNotebook({
    required String spaceId,
    required String question,
    required String answer,
    String? chatId,
    String? assistantTimestamp,
    List<String>? tags,
    String? spaceName,
  }) async {
    final cleanAnswer = formatChatAnswer(answer);
    final title = deriveTitleFromQuestion(question);
    final content = 'Q: ${question.trim()}\n\nA: ${cleanAnswer.trim()}';
    final metadata = <String, dynamic>{
      'question': question.trim(),
      'clean_answer': cleanAnswer.trim(),
    };
    if (chatId != null) metadata['chat_id'] = chatId;
    if (assistantTimestamp != null) metadata['assistant_timestamp'] = assistantTimestamp;
    if (spaceName != null) metadata['space_name'] = spaceName;

    return await LocalDatabaseService.createNotebookEntry(
      spaceId: spaceId,
      title: title,
      content: content,
      sourceType: 'chat',
      sourceId: chatId,
      tags: tags ?? ['chat', 'saved_from_reply'],
      metadata: metadata,
    );
  }

  static Future<List<NotebookEntry>> listNotebookEntries({
    String? spaceId,
  }) async {
    return await LocalDatabaseService.getNotebookEntries(spaceId: spaceId);
  }

  static Future<NotebookEntry> getNotebookEntry(String entryId) async {
    final entry = await LocalDatabaseService.getNotebookEntry(entryId);
    if (entry == null) throw Exception('Notebook entry not found: $entryId');
    return entry;
  }

  static Future<NotebookEntry> updateNotebookEntry({
    required String entryId,
    String? title,
    String? content,
    List<String>? tags,
  }) async {
    return await LocalDatabaseService.updateNotebookEntry(
      entryId,
      title: title,
      content: content,
      tags: tags,
    );
  }

  static Future<void> deleteNotebookEntry(String entryId) async {
    await LocalDatabaseService.deleteNotebookEntry(entryId);
  }

  // =========================================================================
  // PDF EXPORT METHODS (On-Device Syncfusion PDF)
  // =========================================================================

  static Future<PdfDownloadResult> exportSingleAnswerPdf({
    required String spaceId,
    required String question,
    required String answer,
    String? title,
  }) async {
    final cleanAnswer = formatChatAnswer(answer);
    return await PdfExportService.generateSingleAnswerPdf(
      question: question,
      answer: cleanAnswer,
      spaceName: spaceId,
    );
  }

  static Future<PdfDownloadResult> exportCombinedAnswersPdf({
    required String spaceId,
    required String chatTitle,
    required List<Map<String, String>> items,
  }) async {
    final cleanItems = items.map((item) {
      final q = item['question'] ?? 'Question';
      final a = formatChatAnswer(item['answer'] ?? '');
      return {'question': q, 'answer': a};
    }).toList();

    return await PdfExportService.generateCombinedAnswersPdf(
      title: chatTitle,
      items: cleanItems,
      spaceName: spaceId,
    );
  }

  static Future<PdfDownloadResult> exportNotebookEntryPdf({
    required String entryId,
  }) async {
    final entry = await getNotebookEntry(entryId);
    return await PdfExportService.generateNotebookEntryPdf(
      entry: entry,
    );
  }

  static Future<PdfDownloadResult> exportNotebookSpacePdf({
    required String spaceId,
  }) async {
    final entries = await listNotebookEntries(spaceId: spaceId);
    return await PdfExportService.generateSelectedNotebookEntriesPdf(
      entries: entries,
      spaceName: spaceId,
      title: 'Notebook Space Export',
    );
  }

  static Future<PdfDownloadResult> exportSelectedNotebookEntriesPdf({
    required String spaceId,
    required List<String> entryIds,
    String? title,
  }) async {
    final allEntries = await listNotebookEntries(spaceId: spaceId);
    final selected = allEntries.where((e) => entryIds.contains(e.id)).toList();
    return await PdfExportService.generateSelectedNotebookEntriesPdf(
      entries: selected,
      spaceName: spaceId,
      title: title ?? 'Notebook Selection',
    );
  }

  // =========================================================================
  // FLASHCARD METHODS
  // =========================================================================

  static Future<Flashcard> createFlashcard({
    required String spaceId,
    required String question,
    required String answer,
    DifficultyLevel difficulty = DifficultyLevel.medium,
    String sourceType = 'manual',
    List<String>? tags,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/flashcards'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        'space_id': spaceId,
        'question': question,
        'answer': answer,
        'difficulty': difficulty.toJson(),
        'source_type': sourceType,
        'tags': tags ?? [],
      }),
    );

    if (response.statusCode == 200) {
      return Flashcard.fromJson(jsonDecode(response.body));
    } else {
      _throwHttpError('Failed to create flashcard', response);
    }
  }

  static Future<List<Flashcard>> listFlashcards({
    String? spaceId,
    MasteryLevel? mastery,
  }) async {
    final url = await ApiService.getBaseUrl();
    final queryParams = <String, String>{};
    if (spaceId != null) queryParams['space_id'] = spaceId;
    if (mastery != null) queryParams['mastery'] = mastery.toJson();

    final uri = Uri.parse('$url/api/studio/flashcards')
        .replace(queryParameters: queryParams.isNotEmpty ? queryParams : null);

    final response = await http.get(uri, headers: _headers(url));

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((json) => Flashcard.fromJson(json)).toList();
    } else {
      _throwHttpError('Failed to load flashcards', response);
    }
  }

  static Future<Flashcard> reviewFlashcard({
    required String cardId,
    required bool correct,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/flashcards/$cardId/review'),
      headers: _headers(url, json: true),
      body: jsonEncode({'correct': correct}),
    );

    if (response.statusCode == 200) {
      return Flashcard.fromJson(jsonDecode(response.body));
    } else {
      _throwHttpError('Failed to review flashcard', response);
    }
  }

  static Future<void> deleteFlashcard(String cardId) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.delete(
      Uri.parse('$url/api/studio/flashcards/$cardId'),
      headers: _headers(url),
    );

    if (response.statusCode != 200) {
      _throwHttpError('Failed to delete flashcard', response);
    }
  }

  static Future<List<Flashcard>> generateFlashcards({
    required String spaceId,
    required String sourceType,
    List<String>? sourceIds,
    String? textContent,
    int numCards = 5,
    DifficultyLevel difficulty = DifficultyLevel.medium,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/flashcards/generate'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        'space_id': spaceId,
        'source_type': sourceType,
        'source_ids': sourceIds,
        'text_content': textContent,
        'num_cards': numCards,
        'difficulty': difficulty.toJson(),
      }),
    );

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((json) => Flashcard.fromJson(json)).toList();
    } else {
      _throwHttpError('Failed to generate flashcards', response);
    }
  }

  // =========================================================================
  // QUIZ METHODS
  // =========================================================================

  static Future<Quiz> createQuiz({
    required String spaceId,
    required String title,
    String? description,
    required List<QuizQuestion> questions,
    String sourceType = 'manual',
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/quizzes'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        'space_id': spaceId,
        'title': title,
        'description': description,
        'questions': questions.map((q) => q.toJson()).toList(),
        'source_type': sourceType,
      }),
    );

    if (response.statusCode == 200) {
      return Quiz.fromJson(jsonDecode(response.body));
    } else {
      _throwHttpError('Failed to create quiz', response);
    }
  }

  static Future<List<Quiz>> listQuizzes({String? spaceId}) async {
    final url = await ApiService.getBaseUrl();
    final uri = Uri.parse('$url/api/studio/quizzes').replace(
        queryParameters: spaceId != null ? {'space_id': spaceId} : null);

    final response = await http.get(uri, headers: _headers(url));

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((json) => Quiz.fromJson(json)).toList();
    } else {
      _throwHttpError('Failed to load quizzes', response);
    }
  }

  static Future<Quiz> getQuiz(String quizId) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.get(
      Uri.parse('$url/api/studio/quizzes/$quizId'),
      headers: _headers(url),
    );

    if (response.statusCode == 200) {
      return Quiz.fromJson(jsonDecode(response.body));
    } else {
      _throwHttpError('Failed to load quiz', response);
    }
  }

  static Future<void> deleteQuiz(String quizId) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.delete(
      Uri.parse('$url/api/studio/quizzes/$quizId'),
      headers: _headers(url),
    );

    if (response.statusCode != 200) {
      _throwHttpError('Failed to delete quiz', response);
    }
  }

  static Future<Quiz> generateQuiz({
    required String spaceId,
    required String title,
    required String sourceType,
    List<String>? sourceIds,
    String? textContent,
    int numQuestions = 5,
    List<QuestionType>? questionTypes,
    DifficultyLevel difficulty = DifficultyLevel.medium,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/quizzes/generate'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        'space_id': spaceId,
        'title': title,
        'source_type': sourceType,
        'source_ids': sourceIds,
        'text_content': textContent,
        'num_questions': numQuestions,
        'question_types':
            questionTypes?.map((t) => t.toJson()).toList() ?? ['multiple_choice'],
        'difficulty': difficulty.toJson(),
      }),
    );

    if (response.statusCode == 200) {
      return Quiz.fromJson(jsonDecode(response.body));
    } else {
      _throwHttpError('Failed to generate quiz', response);
    }
  }

  static Future<QuizResult> submitQuiz({
    required String quizId,
    required List<QuizAnswer> answers,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/quizzes/$quizId/submit'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        'quiz_id': quizId,
        'answers': answers.map((a) => a.toJson()).toList(),
      }),
    );

    if (response.statusCode == 200) {
      return QuizResult.fromJson(jsonDecode(response.body));
    } else {
      _throwHttpError('Failed to submit quiz', response);
    }
  }
}
