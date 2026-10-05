// Studio Models - Notebook, Flashcards, Quiz
// These models match the backend Pydantic models

// ============================================================================
// NOTEBOOK MODELS
// ============================================================================

class NotebookEntry {
  final String id;
  final String spaceId;
  final String title;
  final String content;
  final String sourceType;
  final String? sourceId;
  final List<String> tags;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, dynamic> metadata;

  NotebookEntry({
    required this.id,
    required this.spaceId,
    required this.title,
    required this.content,
    this.sourceType = 'manual',
    this.sourceId,
    this.tags = const [],
    required this.createdAt,
    required this.updatedAt,
    this.metadata = const {},
  });

  factory NotebookEntry.fromJson(Map<String, dynamic> json) {
    return NotebookEntry(
      id: json['id'],
      spaceId: json['space_id'],
      title: json['title'],
      content: json['content'],
      sourceType: json['source_type'] ?? 'manual',
      sourceId: json['source_id'],
      tags: List<String>.from(json['tags'] ?? []),
      createdAt: DateTime.parse(json['created_at']),
      updatedAt: DateTime.parse(json['updated_at']),
      metadata: json['metadata'] ?? {},
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'space_id': spaceId,
      'title': title,
      'content': content,
      'source_type': sourceType,
      'source_id': sourceId,
      'tags': tags,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'metadata': metadata,
    };
  }
}

// ============================================================================
// FLASHCARD MODELS
// ============================================================================

enum DifficultyLevel {
  easy,
  medium,
  hard;

  String toJson() => name;

  static DifficultyLevel fromJson(String value) {
    return DifficultyLevel.values.firstWhere((e) => e.name == value);
  }
}

enum MasteryLevel {
  newCard('new'),
  learning('learning'),
  reviewing('reviewing'),
  mastered('mastered');

  final String value;
  const MasteryLevel(this.value);

  String toJson() => value;

  static MasteryLevel fromJson(String value) {
    return MasteryLevel.values.firstWhere((e) => e.value == value);
  }
}

class Flashcard {
  final String id;
  final String spaceId;
  final String question;
  final String answer;
  final DifficultyLevel difficulty;
  final MasteryLevel mastery;
  final String sourceType;
  final String? sourceId;
  final List<String> tags;
  final int reviewCount;
  final int correctCount;
  final DateTime? lastReviewed;
  final DateTime? nextReview;
  final DateTime createdAt;
  final Map<String, dynamic> metadata;

  Flashcard({
    required this.id,
    required this.spaceId,
    required this.question,
    required this.answer,
    this.difficulty = DifficultyLevel.medium,
    this.mastery = MasteryLevel.newCard,
    this.sourceType = 'manual',
    this.sourceId,
    this.tags = const [],
    this.reviewCount = 0,
    this.correctCount = 0,
    this.lastReviewed,
    this.nextReview,
    required this.createdAt,
    this.metadata = const {},
  });

  factory Flashcard.fromJson(Map<String, dynamic> json) {
    return Flashcard(
      id: json['id'],
      spaceId: json['space_id'],
      question: json['question'],
      answer: json['answer'],
      difficulty: DifficultyLevel.fromJson(json['difficulty'] ?? 'medium'),
      mastery: MasteryLevel.fromJson(json['mastery'] ?? 'new'),
      sourceType: json['source_type'] ?? 'manual',
      sourceId: json['source_id'],
      tags: List<String>.from(json['tags'] ?? []),
      reviewCount: json['review_count'] ?? 0,
      correctCount: json['correct_count'] ?? 0,
      lastReviewed: json['last_reviewed'] != null
          ? DateTime.parse(json['last_reviewed'])
          : null,
      nextReview: json['next_review'] != null
          ? DateTime.parse(json['next_review'])
          : null,
      createdAt: DateTime.parse(json['created_at']),
      metadata: json['metadata'] ?? {},
    );
  }

  double get accuracy =>
      reviewCount > 0 ? (correctCount / reviewCount * 100) : 0.0;
}

// ============================================================================
// QUIZ MODELS
// ============================================================================

enum QuestionType {
  multipleChoice('multiple_choice'),
  trueFalse('true_false'),
  shortAnswer('short_answer');

  final String value;
  const QuestionType(this.value);

  String toJson() => value;

  static QuestionType fromJson(String value) {
    return QuestionType.values.firstWhere((e) => e.value == value);
  }
}

class QuizQuestion {
  final String id;
  final String question;
  final QuestionType type;
  final List<String>? options;
  final String correctAnswer;
  final String? explanation;
  final int points;
  final DifficultyLevel difficulty;

  QuizQuestion({
    required this.id,
    required this.question,
    required this.type,
    this.options,
    required this.correctAnswer,
    this.explanation,
    this.points = 1,
    this.difficulty = DifficultyLevel.medium,
  });

  factory QuizQuestion.fromJson(Map<String, dynamic> json) {
    return QuizQuestion(
      id: json['id'],
      question: json['question'],
      type: QuestionType.fromJson(json['type'] ?? 'multiple_choice'),
      options: json['options'] != null
          ? List<String>.from(json['options'])
          : null,
      correctAnswer: json['correct_answer'],
      explanation: json['explanation'],
      points: json['points'] ?? 1,
      difficulty: DifficultyLevel.fromJson(json['difficulty'] ?? 'medium'),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'question': question,
      'type': type.toJson(),
      'options': options,
      'correct_answer': correctAnswer,
      'explanation': explanation,
      'points': points,
      'difficulty': difficulty.toJson(),
    };
  }
}

class Quiz {
  final String id;
  final String spaceId;
  final String title;
  final String? description;
  final List<QuizQuestion> questions;
  final String sourceType;
  final List<String>? sourceIds;
  final DateTime createdAt;
  final Map<String, dynamic> metadata;

  Quiz({
    required this.id,
    required this.spaceId,
    required this.title,
    this.description,
    required this.questions,
    this.sourceType = 'manual',
    this.sourceIds,
    required this.createdAt,
    this.metadata = const {},
  });

  factory Quiz.fromJson(Map<String, dynamic> json) {
    return Quiz(
      id: json['id'],
      spaceId: json['space_id'],
      title: json['title'],
      description: json['description'],
      questions: (json['questions'] as List)
          .map((q) => QuizQuestion.fromJson(q))
          .toList(),
      sourceType: json['source_type'] ?? 'manual',
      sourceIds: json['source_ids'] != null
          ? List<String>.from(json['source_ids'])
          : null,
      createdAt: DateTime.parse(json['created_at']),
      metadata: json['metadata'] ?? {},
    );
  }

  int get totalPoints => questions.fold(0, (sum, q) => sum + q.points);
}

class QuizAnswer {
  final String questionId;
  final String answer;
  final int? timeSpent;

  QuizAnswer({
    required this.questionId,
    required this.answer,
    this.timeSpent,
  });

  Map<String, dynamic> toJson() {
    return {
      'question_id': questionId,
      'answer': answer,
      'time_spent': timeSpent,
    };
  }
}

class QuizResult {
  final String quizId;
  final String submissionId;
  final int totalQuestions;
  final int correctAnswers;
  final int incorrectAnswers;
  final double scorePercentage;
  final int totalPoints;
  final int earnedPoints;
  final List<Map<String, dynamic>> answers;
  final DateTime completedAt;
  final int? timeTaken;

  QuizResult({
    required this.quizId,
    required this.submissionId,
    required this.totalQuestions,
    required this.correctAnswers,
    required this.incorrectAnswers,
    required this.scorePercentage,
    required this.totalPoints,
    required this.earnedPoints,
    required this.answers,
    required this.completedAt,
    this.timeTaken,
  });

  factory QuizResult.fromJson(Map<String, dynamic> json) {
    return QuizResult(
      quizId: json['quiz_id'],
      submissionId: json['submission_id'],
      totalQuestions: json['total_questions'],
      correctAnswers: json['correct_answers'],
      incorrectAnswers: json['incorrect_answers'],
      scorePercentage: (json['score_percentage'] as num).toDouble(),
      totalPoints: json['total_points'],
      earnedPoints: json['earned_points'],
      answers: List<Map<String, dynamic>>.from(json['answers']),
      completedAt: DateTime.parse(json['completed_at']),
      timeTaken: json['time_taken'],
    );
  }

  bool get passed => scorePercentage >= 60.0;
}
