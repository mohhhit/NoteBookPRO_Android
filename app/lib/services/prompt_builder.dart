enum AnswerUseCase { explanation, qa, summary, notes }

/// Prompt assembly for the on-device model.
///
/// Ported from the original Python LLMGenerator (_build_system_prompt,
/// _build_user_message, _build_quality_checklist) with these differences:
///  * no content-specific examples and no domain words (the model copies them),
///  * the "never mention missing detail" rule is NOT ported; gaps are reported
///    by app code instead of by the model,
///  * the academic checklist is gated on evidence found in the retrieved text,
///  * SOURCE AGE is only mentioned when there are two or more valid years,
///  * everything is short, because prefill is ~25 tokens/s on this phone.
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
      r"^(what is|what are|what's|explain|describe|define|tell me about|overview of|introduce|how does|how do|difference|differences|compare|contrast|versus|\bvs\b)\b",
    ).hasMatch(q) || RegExp(r'\b(difference between|differences between|\bvs\b|\bversus\b|compared to)\b').hasMatch(q)) {
      return AnswerUseCase.explanation;
    }
    return AnswerUseCase.qa;
  }

  static const List<String> _academicTriggers = [
    'evaluate', 'evaluation', 'compare', 'contrast', 'analyze', 'analyse',
    'analysis', 'justify', 'derive', 'mathematical', 'formula', 'metric',
    'metrics', 'bleu', 'rouge', 'meteor', 'bertscore', 'nlp', 'transformer',
    'limitations', 'assumptions', 'deep learning', 'exam', 'academic',
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

  /// Verb tokens that indicate mechanistic / action sentences worth keeping
  /// even when they don't share query-term overlap (e.g. entity-only queries).
  static const Set<String> _actionVerbs = {
    'automate', 'automates', 'automated', 'automating',
    'trigger', 'triggers', 'triggered', 'triggering',
    'define', 'defines', 'defined', 'defining',
    'run', 'runs', 'running',
    'deploy', 'deploys', 'deployed', 'deploying',
    'initiate', 'initiates', 'initiated', 'initiating',
    'execute', 'executes', 'executed', 'executing',
    'integrate', 'integrates', 'integrated', 'integrating',
    'validate', 'validates', 'validated', 'validating',
    'manage', 'manages', 'managed', 'managing',
    'orchestrate', 'orchestrates', 'orchestrated', 'orchestrating',
    'rollout', 'rollouts',
    'benchmark', 'benchmarks',
    'schedule', 'schedules', 'scheduled', 'scheduling',
    'monitor', 'monitors', 'monitored', 'monitoring',
    'build', 'builds', 'building',
    'test', 'tests', 'tested', 'testing',
    'track', 'tracks', 'tracking',
    'stage', 'stages', 'step', 'steps',
    'pipeline', 'pipelines', 'jenkinsfile',
    'hdfs', 'hadoop', 'parquet', 'orc', 'csv', 'json', 'avro',
    'unstructured', 'semistructured', 'lakehouse', 'acid', 'transaction', 'transactions',
    'object', 's3', 'adls', 'gcs', 'storage', 'compute', 'presto', 'spark', 'trino',
    'decouple', 'decoupled', 'columnar', 'schema-on-read', 'schema-on-write',
  };

  /// Pattern matching introductory phrases that precede lists or steps.
  static final RegExp _continuationIntro = RegExp(
    r'(?::|\b(?:to|such as|including|following|includes|consists of))\s*:?\s*$',
    caseSensitive: false,
  );

  /// Keep the header plus the sentences that best match the question.
  /// Cuts prefill: chunks over [maxChars] shrink to their best sentences.
  ///
  /// Improvements:
  /// - [maxChars] raised to 950 to preserve technical depth.
  /// - Action-verb bonus (+2) so mechanistic sentences score even when the
  ///   entity name is absent (entity-only queries like "Explain Jenkins").
  /// - Continuation rule: if a kept sentence ends with ":", "to", "such as",
  ///   "including" or "following", keep the next 2-4 fragments/list items.
  /// - Neighbor window: also keep adjacent sentences so surrounding context
  ///   is not lost.
  static String compressChunk(
    String chunk,
    String question, {
    int maxSentences = 5,
    int maxChars = 950,
  }) {
    final nl = chunk.indexOf('\n');
    if (nl == -1) return chunk;
    final header = chunk.substring(0, nl);
    final body = chunk.substring(nl + 1).trim();

    // Extract a short label from the header for logging (up to first ']')
    final headerLabel = header.length > 60 ? header.substring(0, 60) : header;

    if (body.length <= maxChars) return chunk;

    final sentences = body
        .split(RegExp(r'(?<=[.!?])\s+|\n\s*[-*•]?\s*|\n+'))
        .map((s) => s.trim())
        .where((s) => s.length > 12 && !s.toLowerCase().contains('sha256'))
        .toList();
    if (sentences.isEmpty) return '$header\n${body.substring(0, maxChars)}';

    final q = _terms(question);

    // Score each sentence: term overlap + verb bonus
    final scores = <int>[];
    for (var i = 0; i < sentences.length; i++) {
      final sLower = sentences[i].toLowerCase();
      final termOverlap = _terms(sentences[i]).where(q.contains).length;
      final verbBonus = _actionVerbs.any((v) => sLower.contains(v)) ? 2 : 0;
      scores.add(termOverlap + verbBonus);
    }

    // Rank by score descending, then by original position ascending
    final ranked = List<int>.generate(sentences.length, (i) => i)
      ..sort((a, b) {
        final byScore = scores[b].compareTo(scores[a]);
        return byScore != 0 ? byScore : a.compareTo(b);
      });

    // Collect chosen indices: selected sentence + continuation items + neighbor window
    final chosenSet = <int>{};
    for (final idx in ranked) {
      if (chosenSet.length >= maxSentences * 4) break;
      chosenSet.add(idx);

      final s = sentences[idx].trim();
      final isContinuation = s.endsWith(':') || _continuationIntro.hasMatch(s);
      final count = isContinuation ? 4 : 2;

      for (var offset = 1; offset <= count; offset++) {
        if (idx + offset < sentences.length) {
          chosenSet.add(idx + offset);
        }
      }
    }

    final chosen = chosenSet.toList()..sort();
    final kept = StringBuffer();
    for (var ci = 0; ci < chosen.length; ci++) {
      final i = chosen[ci];
      if (kept.length + sentences[i].length > maxChars && kept.isNotEmpty) break;
      if (kept.isNotEmpty) {
        final prev = sentences[chosen[ci - 1]].trim();
        if (prev.endsWith(':') || _continuationIntro.hasMatch(prev) || sentences[i].startsWith('-') || sentences[i].startsWith('*')) {
          kept.write('\n');
        } else {
          kept.write(' ');
        }
      }
      kept.write(sentences[i]);
    }

    print('[COMPRESS] chunk "$headerLabel": original ${body.length} chars → compressed ${kept.length} chars, sentences kept: $chosen');
    return '$header\n$kept';
  }

  static List<String> prepareChunks(
    List<String>? raw,
    String question, {
    bool compress = true,
    int maxChunks = 6,
  }) {
    final out = <String>[];
    for (final c in (raw ?? const <String>[]).take(maxChunks)) {
      var chunk = cleanChunkHeader(c);
      if (compress) chunk = compressChunk(chunk, question);
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
      'Master-level data science coursework. Turn the retrieved textbook '
      'excerpts into accurate, well-structured study material.',
    );
    b.writeln();
    b.writeln(
      'GROUNDING: Use ONLY information that appears in the provided context. '
      'Never use outside knowledge and never guess. If the context does not '
      'cover part of the question, leave that part out instead of filling it in. '
      'Ignore excerpts that use the term in a different sense, such as a person\'s name '
      '(e.g., author names or academic citations) or an index/page listing. '
      'Only explain the actual technology or concept asked about.',
    );
    b.writeln(
      'TECHNICAL ACCURACY & PRECISION:\n'
      '- Schema enforcement / schema-on-write validates table structures, data types, and '
      'constraint compliance before writing. It does NOT guarantee semantic data correctness, '
      'truth, or accuracy of the underlying facts. Never claim that schema enforcement guarantees '
      'data correctness or error-free data; describe it as enforcing structural conformity and constraints.\n'
      '- In comparisons, explain cost and scaling trade-offs with specific architectural reasons '
      '(e.g., storage-compute coupling vs independent elasticity; commodity object stores like S3/HDFS '
      'vs proprietary relational compute clusters; write-time indexing cost vs raw storage economics). '
      'Avoid vague generalizations like "warehouses are expensive".',
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
      '- Avoid subjective or promotional buzzwords ("seamless", "essential", '
      '"crucial", "robust", "powerful", "ideal", "game-changing").',
    );
    b.writeln(
      '- STRICT NO-REPETITION: State each fact once. Never repeat the same bold '
      'term across multiple bullets. Never repeat the same definition or mechanism '
      'by swapping words or padding sentences. Every bullet must introduce a fresh, '
      'distinct component or concept.',
    );
    b.writeln(
      '- For questions about workflows, lifecycles, or processes: structure '
      'Key Points as the step-by-step execution flow or architectural stages '
      '(e.g., Build -> Distribute -> Execute, or Engine -> containerd -> runc), '
      'explaining how stages interact instead of repeating isolated definitions.',
    );
    b.writeln(
      '- For comparison questions (differences, vs, compare): explicitly compare both '
      'entities across concrete technical dimensions (e.g., Schema, Data Types, Workloads, '
      'Storage Architecture, Cost/Governance). Each bullet under "### Key Points" must represent a '
      'technical comparison dimension and contrast how both entities handle that dimension '
      '(e.g., "- **Schema**: Entity A enforces schema-on-write with relational models, while Entity B applies schema-on-read over raw files [1, 2]."). '
      'Never emit an empty bullet, a lone entity name, or an unelaborated label.',
    );
    b.writeln(
      '- Where the context has them, explain mechanisms, formulas, '
      'limitations and failure modes, and contrast older with newer approaches.',
    );
    b.writeln(
      '- Use ### headings and bullets with **bold key terms**. No glossary, '
      'no follow-up questions, and never use a table of contents or chapter summary '
      'as an explanation.',
    );
    b.writeln(
      r'- Write equations in LaTeX ($...$ inline, $$...$$ block) only if the '
      'formula appears intact in the context; otherwise describe it in words. '
      'Tables must be valid markdown tables.',
    );
    b.writeln();
    b.write(_task(uc));
    b.writeln();
    b.writeln(
      'CITATIONS: End every factual sentence or bullet with its excerpt '
      'number in brackets: [n] or [n, m]. Numbers only; never a year, '
      'filename or the word "Source". Uncited sentences will be removed.',
    );
    if (uc == AnswerUseCase.explanation) {
      b.writeln();
      b.writeln('FORMAT (placeholders, not content):');
      b.writeln('### Definition and Core Architecture');
      b.writeln('<Subject> is <category> that <purpose> [1].');
      b.writeln('- **<Term>**: <what it does or means> [1, 2].');
      b.writeln('* **<Foundational Component>:** <infrastructure and storage details> [2].');
      b.writeln('* **<Data Formats / Specs>:** <supported formats, schemas, or protocols> [3].');
      b.writeln();
      b.writeln('### Operational Characteristics and Interoperability');
      b.writeln('* **<Execution & Portability>:** <execution engines and workload processing> [3, 4].');
      b.writeln('* **<Ecosystem Integration>:** <integration across downstream systems> [4].');
      b.writeln();
      b.writeln('### Limitations and Modern Evolution');
      b.writeln('* **<Operational Limitations>:** <challenges, lack of guarantees, or trade-offs> [5].');
      b.writeln('* **<Modern Convergence>:** <evolution toward next-generation patterns or ACID controls> [5, 6].');
    }
    return b.toString();
  }

  static String _task(AnswerUseCase uc) => switch (uc) {
        AnswerUseCase.explanation =>
          'TASK: Explain the concept, system, or comparison for an advanced student.\n'
              '- Start with "### Definition": 1-2 sentences strictly defining the core concept itself, '
              'highlighting its fundamental nature (e.g. for a data lake, storing massive volumes of raw, '
              'unprocessed data across structured, semistructured, and unstructured formats). '
              'Do not narrow the definition prematurely to a specific vendor, product, or subtype.\n'
              '- For comprehensive/in-depth questions ("Explain ... in detail"), organize the architectural breakdown '
              'across structured, thematic sections (e.g. "### Core Architecture & Storage", "### Operational Characteristics & Interoperability", "### Limitations & Modern Evolution") '
              'with 5 to 8 fact-dense bullets in total:\n'
              '  * Foundational Storage & Infrastructure: Initial infrastructure (e.g. Hadoop HDFS, commodity hardware) vs modern cloud object storage (Amazon S3, Azure ADLS, GCS), separation of compute and storage.\n'
              '  * Data Formats: Support for raw unstructured, semistructured, and open columnar standards (CSV, JSON, ORC, Parquet).\n'
              '  * Operational Characteristics & Ecosystem: Portability across processing engines (Spark, Presto, Trino), schema-on-read, downstream analytical consumption.\n'
              '  * Limitations & Lakehouse Convergence: Original limitations (lack of native transactions, updates/deletes) and the evolution to modern lakehouse architectures with ACID controls.\n'
              '- Each bullet must have a UNIQUE **bold key term** and convey substantive technical claims supported by the excerpts.\n'
              '- Provide thorough, substantive technical depth (typically 250-500 words when context is rich).\n'
              '- End every factual sentence or bullet with its citation [n] or [n, m].\n',
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
    b.writeln();
    b.write(
      'Instructions: Answer ONLY from the context above. If the context does '
      'not contain the answer, say you do not have that information. Cite '
      'sources as [n].',
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
    if (q.contains('bleu') && ctx.contains('brevity')) {
      b.write(' For BLEU, include the brevity penalty.');
    }
    if (q.contains('rouge')) {
      if (ctx.contains('rouge-l') || ctx.contains('lcs')) {
        b.write(' For ROUGE, include ROUGE-N and ROUGE-L (LCS).');
      }
      if (ctx.contains('precision') || ctx.contains('f1')) {
        b.write(' Mention precision, recall and F1 behaviour.');
      }
    }
    if (ctx.contains('bertscore') &&
        (q.contains('bleu') || q.contains('rouge') || q.contains('metric'))) {
      b.write(' Include BERTScore as a modern semantic metric.');
    }
    return b.toString();
  }
}
