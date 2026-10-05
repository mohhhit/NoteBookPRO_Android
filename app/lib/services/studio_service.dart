import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import '../models/studio_models.dart';
import 'api_service.dart';

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
  // NOTEBOOK METHODS
  // =========================================================================

  static Future<NotebookEntry> createNotebookEntry({
    required String spaceId,
    required String title,
    required String content,
    String sourceType = 'manual',
    String? sourceId,
    List<String>? tags,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/notebook'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        'space_id': spaceId,
        'title': title,
        'content': content,
        'source_type': sourceType,
        'source_id': sourceId,
        'tags': tags ?? [],
      }),
    );

    if (response.statusCode == 200) {
      return NotebookEntry.fromJson(jsonDecode(response.body));
    } else {
      _throwHttpError('Failed to create notebook entry', response);
    }
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
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/notebook/from-chat'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        'space_id': spaceId,
        'question': question,
        'answer': answer,
        'chat_id': chatId,
        'assistant_timestamp': assistantTimestamp,
        'tags': tags ?? ['chat'],
        if (spaceName != null) 'space_name': spaceName,
      }),
    );

    if (response.statusCode == 200) {
      return NotebookEntry.fromJson(jsonDecode(response.body));
    } else {
      _throwHttpError('Failed to add chat to notebook', response);
    }
  }

  static Future<List<NotebookEntry>> listNotebookEntries({
    String? spaceId,
  }) async {
    final url = await ApiService.getBaseUrl();
    final uri = Uri.parse('$url/api/studio/notebook')
        .replace(queryParameters: spaceId != null ? {'space_id': spaceId} : null);

    final response = await http.get(uri, headers: _headers(url));

    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      return data.map((json) => NotebookEntry.fromJson(json)).toList();
    } else {
      _throwHttpError('Failed to load notebook entries', response);
    }
  }

  static Future<NotebookEntry> getNotebookEntry(String entryId) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.get(
      Uri.parse('$url/api/studio/notebook/$entryId'),
      headers: _headers(url),
    );

    if (response.statusCode == 200) {
      return NotebookEntry.fromJson(jsonDecode(response.body));
    } else {
      _throwHttpError('Failed to load notebook entry', response);
    }
  }

  static Future<NotebookEntry> updateNotebookEntry({
    required String entryId,
    String? title,
    String? content,
    List<String>? tags,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.put(
      Uri.parse('$url/api/studio/notebook/$entryId'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        if (title != null) 'title': title,
        if (content != null) 'content': content,
        if (tags != null) 'tags': tags,
      }),
    );

    if (response.statusCode == 200) {
      return NotebookEntry.fromJson(jsonDecode(response.body));
    } else {
      _throwHttpError('Failed to update notebook entry', response);
    }
  }

  static Future<void> deleteNotebookEntry(String entryId) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.delete(
      Uri.parse('$url/api/studio/notebook/$entryId'),
      headers: _headers(url),
    );

    if (response.statusCode != 200) {
      _throwHttpError('Failed to delete notebook entry', response);
    }
  }

  static Future<PdfDownloadResult> exportSingleAnswerPdf({
    required String spaceId,
    required String question,
    required String answer,
    String? title,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/notebook/export/answer-pdf'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        'space_id': spaceId,
        'question': question,
        'answer': answer,
        if (title != null) 'title': title,
      }),
    );

    if (response.statusCode == 200) {
      return PdfDownloadResult(
        bytes: response.bodyBytes,
        filename: _extractFilename(response, fallback: 'answer_export.pdf'),
      );
    } else {
      _throwHttpError('Failed to export answer PDF', response);
    }
  }

  static Future<PdfDownloadResult> exportCombinedAnswersPdf({
    required String spaceId,
    required String chatTitle,
    required List<Map<String, String>> items,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/notebook/export/combined-pdf'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        'space_id': spaceId,
        'chat_title': chatTitle,
        'items': items,
      }),
    );

    if (response.statusCode == 200) {
      return PdfDownloadResult(
        bytes: response.bodyBytes,
        filename: _extractFilename(response, fallback: 'combined_answers.pdf'),
      );
    } else {
      _throwHttpError('Failed to export combined PDF', response);
    }
  }

  static Future<PdfDownloadResult> exportNotebookEntryPdf({
    required String entryId,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.get(
      Uri.parse('$url/api/studio/notebook/export/entry/$entryId/pdf'),
      headers: _headers(url),
    );

    if (response.statusCode == 200) {
      return PdfDownloadResult(
        bytes: response.bodyBytes,
        filename: _extractFilename(response, fallback: 'notebook_entry.pdf'),
      );
    } else {
      _throwHttpError('Failed to export notebook entry PDF', response);
    }
  }

  static Future<PdfDownloadResult> exportNotebookSpacePdf({
    required String spaceId,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.get(
      Uri.parse('$url/api/studio/notebook/export/space/$spaceId/combined-pdf'),
      headers: _headers(url),
    );

    if (response.statusCode == 200) {
      return PdfDownloadResult(
        bytes: response.bodyBytes,
        filename: _extractFilename(response, fallback: 'notebook_combined.pdf'),
      );
    } else {
      _throwHttpError('Failed to export combined notebook PDF', response);
    }
  }

  static Future<PdfDownloadResult> exportSelectedNotebookEntriesPdf({
    required String spaceId,
    required List<String> entryIds,
    String? title,
  }) async {
    final url = await ApiService.getBaseUrl();
    final response = await http.post(
      Uri.parse('$url/api/studio/notebook/export/selected-pdf'),
      headers: _headers(url, json: true),
      body: jsonEncode({
        'space_id': spaceId,
        'entry_ids': entryIds,
        if (title != null && title.trim().isNotEmpty) 'title': title.trim(),
      }),
    );

    if (response.statusCode == 200) {
      return PdfDownloadResult(
        bytes: response.bodyBytes,
        filename: _extractFilename(
          response,
          fallback: 'notebook_selected_combined.pdf',
        ),
      );
    } else {
      _throwHttpError('Failed to export selected notebook PDF', response);
    }
  }

  static String _extractFilename(http.Response response, {required String fallback}) {
    final contentDisposition = response.headers['content-disposition'];
    if (contentDisposition == null || contentDisposition.isEmpty) {
      return fallback;
    }

    final match = RegExp(r'filename="?([^";]+)"?').firstMatch(contentDisposition);
    return match?.group(1) ?? fallback;
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
