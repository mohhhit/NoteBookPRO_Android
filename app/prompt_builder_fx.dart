import 'dart:math' as math;

enum AnswerUseCase { explanation, comparison, qa, summary, notes }

/// Prompt assembly for the on-device model.
///
/// Ported from the original Python LLMGenerator (_build_system_prompt,
/// _build_user_message, _build_quality_checklist) with these differences:
///  * no content-specific examples and no domain words (the model copies them),
///  * the "never mention missing detail" rule is NOT ported; gaps are reported
///    by app code instead of by the model,
///  * the academic checklist is gated on evidence found in the retrieved text,
///  * SOURCE AGE is only mentioned when there are two or more valid years,
///  * everything is short, because prefill is ~20-25 tokens/s on this phone,
///  * chunk compression ranks sentences by relevance and keeps the best ones
///    within a shared character budget.
///
/// Wiring (inside LocalLlmService.generateResponse):
///   final uc = PromptBuilder.inferUseCase(question);
///   final chunks = PromptBuilder.prepareChunks(contextChunks, question);
///   final system = PromptBuilder.buildSystemPrompt(uc, chunks: chunks);
///   final user = PromptBuilder.buildUserMessage(question, chunks, uc);
/// Put `system` in the Llama system header (static text first, so the prefix
/// can be cached) and `user` in the final user turn.
class PromptBuilder {
  PromptBuilder._();

  // ------------------------------------------------------------- use case

  static AnswerUseCase inferUseCase(String question) {
    final q = question.toLowerCase().trim();
    if (RegExp(r'\b(summari[sz]e|summary|tl;?dr|key takeaways?)\b').hasMatch(q)) {
      return AnswerUseCase.summary;
    }
    if (RegExp(r'\b(study notes?|make notes?|notes on|revision notes?)\b')
        .hasMatch(q)) {
      return AnswerUseCase.notes;
    }
    if (RegExp(
      r'\b(differences?|differ|differs|compare|compared|comparison|versus|vs|contrast)\b',
    ).hasMatch(q)) {
      return AnswerUseCase.comparison;
    }
    if (RegExp(
      r"^(what is|what are|what's|explain|describe|define|tell me about|overview of|introduce|how does|how do)\b",
    ).hasMatch(q)) {
      return AnswerUseCase.explanation;
    }
    return AnswerUseCase.qa;
  }

  // Domain-neutral on purpose. Subject-specific hints go through [extraHints].
  static const List<String> _academicTriggers = [
    'evaluate', 'evaluation', 'compare', 'contrast', 'analyze', 'analyse',
    'analysis', 'justify', 'derive', 'proof', 'prove', 'formula', 'equation',
    'limitations', 'assumptions', 'critically', 'assess', 'exam', 'academic',
  ];

  static bool needsAcademicDepth(String question, AnswerUseCase uc) {
    if (uc == AnswerUseCase.summary) return false;
    final l = question.toLowerCase();
    return _academicTriggers.any((t) => l.contains(t));
  }

  // -------------------------------------------------------------- chunks

  static final RegExp _libTag = RegExp(
    r'\s*\((?:z-library|1lib|z-lib)[^)]*\)(?:\.(?:pdf|epub|docx|txt))?',
    caseSensitive: false,
  );

  /// Remove download-site tags and unknown years from a chunk's header line.
  static String cleanChunkHeader(String chunk) {
    final nl = chunk.indexOf('\n');
    var header = nl == -1 ? chunk : chunk.substring(0, nl);
    final body = nl == -1 ? '' : chunk.substring(nl);
    header = header.replaceAll(_libTag, '');
    header = header.replaceAll(RegExp(r'\.pdf\b', caseSensitive: false), '');
    header = header.replaceAll('[0000] ', '').replaceAll(' (0000)', '');
    // libgen-style titles: "{authors}", "{107716181}", "libgen.li" and
    // "(2024, O& 039 Reilly Media)" -> keep only the year.
    header = header.replaceAll(RegExp(r'\s*\{[^}]*\}'), '');
    header = header.replaceAll(RegExp(r'\s*libgen\.\w+', caseSensitive: false), '');
    header = header.replaceAllMapped(
      RegExp(r'\((\d{4}),\s*[^)]*\)'),
      (m) => '(${m[1]})',
    );
    return '$header$body';
  }

  static const Set<String> _stop = {
    'the', 'and', 'for', 'are', 'but', 'not', 'you', 'all', 'can', 'her',
    'was', 'one', 'our', 'out', 'has', 'have', 'how', 'what', 'when', 'where',
    'which', 'who', 'why', 'with', 'this', 'that', 'from', 'into', 'about',
    'does', 'its', 'their', 'there', 'than', 'then', 'them', 'these', 'those',
    'explain', 'detail', 'give', 'some', 'tell', 'describe', 'define',
  };

  static Set<String> _terms(String s) => RegExp(r'[a-z0-9][a-z0-9\-]{2,}')
      .allMatches(s.toLowerCase())
      .map((m) => m.group(0)!)
      .where((w) => !_stop.contains(w))
      .toSet();

  // Sentence-level scoring used by compressChunk. Textbook intro fluff and
  // code/diagram listings must not eat the budget, and items that follow a
  // matching sentence (list entries, continuations) must survive even though
  // they never repeat the question term.
  static final RegExp _fluff = RegExp(
    r"\b(in this (?:section|chapter|book)|we (?:delve|explore|will|discuss|cover|examine)|let(?:'s| us)|cornerstone|powerful suite|as we conclude|this section)\b",
    caseSensitive: false,
  );
  static final RegExp _action = RegExp(
    r'\b(is one of|is defined as|refers to|consists of|used to|can be used|allows?|enables?|provides?|requires?|ensures?|automatic(?:ally)?|triggers?|defines?|determines?|measures?|produces?|results? in)\b',
    caseSensitive: false,
  );
  // Generic code/markup markers. Only penalized when the question is not about
  // code (see codeQuestion below), so programming textbooks still work.
  static final RegExp _codey = RegExp(
    r"//|\.py\b|[{}]|;\s*$|=>|-->|\bdef\s|\bimport\s",
  );
  static final RegExp _codeQuestion = RegExp(
    r'\b(code|script|syntax|command|function|implement|program|snippet|query|sql|config|api)\b',
    caseSensitive: false,
  );
  static final RegExp _scaffold = RegExp(
    r'\b(below is|illustrative example|following example)\b',
    caseSensitive: false,
  );

  /// Same as [compressChunk] but also reports which sentences were kept,
  /// so you can log it: `[COMPRESS] 1952 -> 850 chars, kept [4,5,6,7,8,9]`.
  ///
  /// Selection is by score, not by position: sentences are ranked, added
  /// greedily until [maxChars] is reached, then put back in reading order.
  /// (Cutting a position-ordered list at the character limit drops the tail,
  /// which is where task lists and mechanisms usually are.)
  static ({String text, List<int> kept, int sentences}) compressChunkDebug(
    String chunk,
    String question, {
    int maxChars = 900,
  }) {
    final nl = chunk.indexOf('\n');
    if (nl == -1) return (text: chunk, kept: const <int>[], sentences: 0);
    final header = chunk.substring(0, nl);
    final body = chunk.substring(nl + 1).trim();
    if (body.length <= maxChars) {
      return (text: chunk, kept: const <int>[], sentences: 0);
    }

    final sentences = body
        .split(RegExp(r'(?<=[.!?])\s+'))
        .map((s) => s.trim())
        .where((s) => s.length >= 12)
        .toList();
    if (sentences.isEmpty) {
      return (
        text: '$header\n${body.substring(0, maxChars)}',
        kept: const <int>[],
        sentences: 0,
      );
    }

    final q = _terms(question);
    final n = sentences.length;
    final base = List<int>.generate(
      n,
      (i) => _terms(sentences[i]).where(q.contains).length,
    );
    final score = base.map((b) => b.toDouble()).toList();

    // Sentences right after a matching one (list items, continuations) inherit
    // part of its relevance; the sentence just before gets a little.
    const forward = [0.7, 0.5, 0.3];
    for (var i = 0; i < n; i++) {
      if (base[i] <= 0) continue;
      for (var k = 0; k < forward.length; k++) {
        if (i + k + 1 < n) score[i + k + 1] += forward[k];
      }
      if (i > 0) score[i - 1] += 0.3;
    }

    final wantsExamples = question.toLowerCase().contains('example');
    final codeQuestion = _codeQuestion.hasMatch(question);
    for (var i = 0; i < n; i++) {
      final s = sentences[i];
      if (_action.hasMatch(s)) score[i] += 0.5;
      if (_fluff.hasMatch(s)) score[i] -= 3;
      if (!codeQuestion && _codey.hasMatch(s)) score[i] -= 3;
      if (!wantsExamples && _scaffold.hasMatch(s)) score[i] -= 1.5;
      if (s.toLowerCase().contains('sha256')) score[i] -= 5;
      final odd = s.replaceAll(RegExp(r'[A-Za-z0-9 ]'), '').length / s.length;
      if (!codeQuestion && odd > 0.2) score[i] -= 2;
    }

    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) {
        final c = score[b].compareTo(score[a]);
        return c != 0 ? c : a.compareTo(b);
      });

    final chosen = <int>[];
    var used = 0;
    for (final i in order) {
      if (score[i] <= 0 && chosen.isNotEmpty) continue;
      if (used + sentences[i].length + 1 > maxChars && chosen.isNotEmpty) {
        continue;
      }
      chosen.add(i);
      used += sentences[i].length + 1;
    }
    chosen.sort();

    final text = '$header\n${chosen.map((i) => sentences[i]).join(' ')}';
    return (text: text, kept: chosen, sentences: n);
  }

  static String compressChunk(
    String chunk,
    String question, {
    int maxChars = 900,
  }) =>
      compressChunkDebug(chunk, question, maxChars: maxChars).text;

  /// Clean headers and compress every chunk. The character budget is shared:
  /// [totalBudgetChars] divided by the number of chunks (450-1200 each), so the
  /// context stays around 700 tokens however many chunks survive reranking.
  static List<String> prepareChunks(
    List<String>? raw,
    String question, {
    bool compress = true,
    int totalBudgetChars = 2400,
    void Function(String message)? log,
  }) {
    final src = raw ?? const <String>[];
    final perChunk = src.isEmpty
        ? 900
        : (totalBudgetChars ~/ src.length).clamp(450, 1200).toInt();
    final out = <String>[];
    for (final c in src) {
      var chunk = cleanChunkHeader(c);
      if (compress) {
        final r = compressChunkDebug(chunk, question, maxChars: perChunk);
        final nl = chunk.indexOf('\n');
        final label = (nl == -1 ? chunk : chunk.substring(0, nl));
        log?.call(
          '[COMPRESS] ${label.length > 60 ? label.substring(0, 60) : label}: '
          '${chunk.length} -> ${r.text.length} chars, '
          'kept ${r.kept} of ${r.sentences} sentences',
        );
        chunk = r.text;
      }
      out.add(chunk);
    }
    return out;
  }

  static Set<String> validYears(List<String> chunks) {
    final years = <String>{};
    final re = RegExp(r'[\[(]((?:19|20)\d{2})[\])]');
    for (final c in chunks) {
      final nl = c.indexOf('\n');
      final header = nl == -1 ? c : c.substring(0, nl);
      for (final m in re.allMatches(header)) {
        years.add(m.group(1)!);
      }
    }
    return years;
  }

  // -------------------------------------------------------- system prompt

  static String buildSystemPrompt(
    AnswerUseCase uc, {
    List<String> chunks = const [],
  }) {
    final b = StringBuffer();
    b.writeln(
      'You are the generation engine for NotebookPRO, a study assistant for '
      'university-level coursework. Turn the retrieved textbook excerpts into '
      'accurate, well-structured study material.',
    );
    b.writeln();
    b.writeln(
      'GROUNDING: Use ONLY information that appears in the provided context. '
      'Never use outside knowledge and never guess. If the context does not '
      'cover part of the question, leave that part out instead of filling it in.',
    );
    if (validYears(chunks).length >= 2) {
      b.writeln(
        'SOURCE AGE: Excerpts carry a year. If sources differ, present the '
        'newest as current practice and older ones as background.',
      );
    }
    b.writeln();
    b.writeln('STYLE:');
    b.writeln(
      '- Write with the authority of a textbook. Never say "based on the '
      'context", "the excerpt states" or "the sources". Do not copy '
      'promotional or tutorial wording ("in this book", "try running", "our", '
      '"we", "earlier", "later").',
    );
    b.writeln(
      '- Where the context has them, explain mechanisms, formulas, '
      'limitations and failure modes, and contrast older with newer approaches.',
    );
    b.writeln(
      '- Use ### headings and bullets with **bold key terms**. State each '
      'fact once. No glossary, no follow-up questions, and never use a table '
      'of contents or chapter summary as an explanation.',
    );
    b.writeln(
      r'- Write equations in LaTeX ($...$ inline, $$...$$ block) only if the '
      'formula appears intact in the context; otherwise describe it in words. '
      'Tables must be valid markdown tables.',
    );
    if (_hasEraEvidence(chunks.join('\n').toLowerCase())) {
      b.writeln(
        '- Keep time and scope qualifiers from the excerpts ("traditionally", '
        '"historically", "in early versions", "modern", "in some cases"). Never '
        'present a historical limitation as a current one. If the excerpts '
        'describe both an older and a newer form, cover both and label each.',
      );
    }
    b.writeln();
    b.write(_task(uc));
    b.writeln();
    b.writeln(
      'CITATIONS: End every factual sentence or bullet with its excerpt '
      'number in brackets: [n] or [n, m]. Numbers only; never a year, '
      'filename or the word "Source". Uncited sentences will be removed.',
    );
    if (uc == AnswerUseCase.comparison) {
      b.writeln();
      b.writeln('FORMAT (placeholders, not content):');
      b.writeln('### Overview');
      b.writeln('<A> is <what> [1]. <B> is <what> [2].');
      b.writeln();
      b.writeln('### Key Differences');
      b.writeln('- **<Aspect>**: <A> <does X>, whereas <B> <does Y> [1, 2].');
    }
    if (uc == AnswerUseCase.explanation) {
      b.writeln();
      b.writeln('FORMAT (placeholders, not content):');
      b.writeln('### Definition');
      b.writeln('<Subject> is <category> that <purpose> [1].');
      b.writeln();
      b.writeln('### Key Points');
      b.writeln('- **<Term>**: <what it does or means> [2].');
    }
    return b.toString();
  }

  static String _task(AnswerUseCase uc) => switch (uc) {
        AnswerUseCase.explanation =>
          'TASK: Explain the concept for an advanced student.\n'
              '- Start with "### Definition": 1-2 sentences saying what it is, '
              'its purpose, and the problem it solves, using wording from the '
              'context.\n'
              '- Then "### Key Points": one bullet per distinct component, step '
              'or mechanism the context supports (as many as it supports, at '
              'most 8; fewer is fine). Say what each term does in one sentence.\n'
              '- Add "### Takeaway" (one sentence) only if the context supports '
              'a clear one.\n'
              '- Usually 120-350 words; shorter when the context is limited.\n',
        AnswerUseCase.comparison =>
          'TASK: Compare the subjects the question names.\n'
              '- Start with "### Overview": one sentence per subject saying what '
              'it is, using wording from the context.\n'
              '- Then "### Key Differences": one bullet per aspect the context '
              'supports (for example purpose, how it works, strengths, '
              'weaknesses, typical use; at most 7). Each bullet states both '
              'sides in one sentence, in the form **Aspect**: A does X, whereas '
              'B does Y [n]. Do not repeat facts from the Overview.\n'
              '- If the context covers only one side of an aspect, say so in '
              'that bullet instead of guessing the other side.\n'
              '- Add "### When to Use Which" (1-2 sentences) only if the context '
              'supports it.\n',
        AnswerUseCase.qa =>
          'TASK: Answer the question directly.\n'
              '- First sentence: the direct answer.\n'
              '- Then supporting bullets that connect points across sources '
              '(mechanisms, reasons, risks, implications) when the context has '
              'them.\n'
              '- Use **bold** for key facts, numbers and formulas. Usually '
              '120-350 words; shorter when the context is limited.\n',
        AnswerUseCase.summary =>
          'TASK: Write a structured summary.\n'
              '- Start with a 2-sentence overview.\n'
              '- Then "### Key Themes" with one concise, fact-dense bullet per '
              'main point.\n',
        AnswerUseCase.notes =>
          'TASK: Write structured study notes.\n'
              '- Use ### section headers and nested bullets.\n'
              '- Highlight **Definitions**, **Formulas** and **Names/Dates** '
              'in bold.\n',
      };

  // --------------------------------------------------------- user message

  static String buildUserMessage(
    String question,
    List<String> chunks,
    AnswerUseCase uc,
  ) {
    final b = StringBuffer();
    if (chunks.isNotEmpty) {
      b.writeln('===== START OF CONTEXT (ANSWER ONLY FROM THIS) =====');
      b.writeln();
      b.writeln(chunks.join('\n\n'));
      b.writeln();
      b.writeln('===== END OF CONTEXT =====');
      b.writeln();
    }
    b.writeln("Student's question: $question");
    final scope = extractScope(question);
    if (scope != null) {
      b.writeln('Scope: discuss only $scope; leave out other aspects.');
    }
    if (isYesNoQuestion(question)) {
      b.writeln(
        'This is a yes/no question: begin with Yes, No or Partly, then give '
        'the evidence from the context. Statements such as "X lacks Y" or '
        '"X requires Y" answer it.',
      );
    }
    b.writeln();
    b.write(
      'Instructions: Answer ONLY from the context above. If the context covers '
      'only part of the question, answer that part and say what is missing; '
      'say you do not have the information only when the context contains '
      'nothing relevant. Cite sources as [n].',
    );
    final checklist = qualityChecklist(question, uc, chunks);
    if (checklist.isNotEmpty) {
      b.write('\n$checklist');
    }
    return b.toString();
  }

  // ------------------------------------------------------------ checklist

  static bool _hasFormulaEvidence(String ctx) => RegExp(
        r'\\frac|\\sum|[∑Σ√]|\b[a-z]\s*=\s*[a-z0-9(]|\bformula\b|\bequation\b',
      ).hasMatch(ctx);

  static bool _hasLimitationEvidence(String ctx) => RegExp(
        r'\b(limitation|drawback|disadvantage|trade-?off|downside|failure|bottleneck|challenge)s?\b',
      ).hasMatch(ctx);

  // ---------------------------------------------------------- scope & eras

  static final RegExp _scopeRe = RegExp(
    r'\b(?:in terms of|with respect to|with regard to|regarding|focusing on|specifically (?:about|for|in))\s+([^?.!]+)',
    caseSensitive: false,
  );

  /// "... in terms of data storage" -> "data storage". Null when the question
  /// does not restrict its scope.
  static String? extractScope(String question) {
    final m = _scopeRe.firstMatch(question);
    if (m == null) return null;
    final scope = m.group(1)!.trim();
    return scope.length < 3 ? null : scope;
  }

  static final RegExp _yesNoRe = RegExp(
    r'^(does|do|did|is|are|was|were|can|could|should|will|would|has|have|had)\b',
    caseSensitive: false,
  );

  static bool isYesNoQuestion(String question) =>
      _yesNoRe.hasMatch(question.trim());

  /// Domain-neutral retrieval facets for questions where an older and a newer
  /// form of the same thing may both be described (add them next to your
  /// other facets; give each its own candidate pool).
  static List<String> eraFacets(String topic) => [
        '$topic traditional legacy earlier approach',
        '$topic modern current recent approach',
      ];

  static bool _hasEraEvidence(String ctx) => RegExp(
        r'\b(traditional(?:ly)?|legacy|historically|originally|early (?:systems?|versions?)|older|modern|nowadays|evolved)\b',
      ).hasMatch(ctx);

  /// Optional subject-specific hints; empty by default so the builder stays
  /// domain-neutral. A hint is added only when the question matches AND the
  /// retrieved text matches (both are tested against lower-cased text, so use
  /// case-insensitive patterns). Example shape:
  ///   extraHints.add((question: RegExp(r'\bterm\b'), evidence: RegExp(r'detail'),
  ///                   hint: 'Mention the detail.'));
  static final List<({RegExp question, RegExp evidence, String hint})>
      extraHints = [];

  /// Port of _build_quality_checklist. Each item appears only when the
  /// retrieved text actually contains something to support it.
  static String qualityChecklist(
    String question,
    AnswerUseCase uc,
    List<String> chunks,
  ) {
    if (!needsAcademicDepth(question, uc)) return '';
    final ctx = chunks.join('\n').toLowerCase();
    final items = <String>['core mechanism details, not just definitions'];
    if (_hasFormulaEvidence(ctx)) {
      items.add('the relevant formula, in LaTeX, if it appears intact');
    }
    if (_hasLimitationEvidence(ctx)) {
      items.add('the limitations or failure cases the context mentions');
    }
    if (validYears(chunks).length >= 2) {
      items.add('how older and newer approaches differ, if the context says');
    }

    final b = StringBuffer(
      'Cover, only where the context supports it: ${items.join('; ')}. '
      'Leave out anything the context does not contain.',
    );

    final q = question.toLowerCase();
    for (final h in extraHints) {
      if (h.question.hasMatch(q) && h.evidence.hasMatch(ctx)) {
        b.write(' ${h.hint}');
      }
    }
    return b.toString();
  }
}
