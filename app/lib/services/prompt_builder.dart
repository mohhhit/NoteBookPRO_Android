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
    // Comparison use case: detect differences, contrasts, vs, compare
    if (RegExp(
      r'\b(differ(?:ence|ences)?\s+between|compare|contrast|\bvs\.?\b|\bversus\b|compared\s+to)\b',
      caseSensitive: false,
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

  /// Extracts a restrictive scope phrase (e.g. "in terms of data storage", "regarding latency").
  static String? extractScopePhrase(String question) {
    final match = RegExp(
      r'\b(?:in\s+terms\s+of|regarding|with\s+respect\s+to|focusing\s+on|specifically\s+(?:for|in|about)|in\s+relation\s+to|from\s+the\s+perspective\s+of)\s+([^?.,;]+)',
      caseSensitive: false,
    ).firstMatch(question);
    if (match != null) {
      final scope = match.group(1)!.trim();
      if (scope.isNotEmpty) return scope;
    }
    return null;
  }

  static const List<String> _academicTriggers = [
    'evaluate', 'evaluation', 'compare', 'contrast', 'analyze', 'analyse',
    'analysis', 'justify', 'derive', 'mathematical', 'formula', 'metric',
    'metrics', 'bleu', 'rouge', 'meteor', 'bertscore', 'nlp', 'transformer',
    'limitations', 'assumptions', 'deep learning', 'exam', 'academic',
  ];

  static bool needsAcademicDepth(String question, AnswerUseCase uc) {
    if (uc == AnswerUseCase.summary) return false;
    if (uc == AnswerUseCase.explanation || uc == AnswerUseCase.comparison) return true;
    final l = question.toLowerCase();
    return _academicTriggers.any((t) => l.contains(t)) ||
        l.contains('in detail') ||
        l.contains('detail');
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
    'pipeline', 'pipelines',
    'compute', 'computes', 'computed', 'computing',
    'process', 'processes', 'processed', 'processing',
    'transform', 'transforms', 'transformed', 'transforming',
    'optimize', 'optimizes', 'optimized', 'optimizing',
    'converge', 'converges', 'converged', 'converging',
    'isolate', 'isolates', 'isolated', 'isolating',
    'scale', 'scales', 'scaled', 'scaling',
    'enforce', 'enforces', 'enforced', 'enforcing',
    'evaluate', 'evaluates', 'evaluated', 'evaluating',
    'retrieve', 'retrieves', 'retrieved', 'retrieving',
    'transmit', 'transmits', 'transmitted', 'transmitting',
    'synthesize', 'synthesizes', 'synthesized', 'synthesizing',
    'configure', 'configures', 'configured', 'configuring',
    'serialize', 'serializes', 'serialized', 'serializing',
    'instantiate', 'instantiates', 'instantiated', 'instantiating',
    'serve', 'serves', 'serving', 'served',
    'parse', 'parses', 'parsing', 'parsed',
    'dispatch', 'dispatches', 'dispatching', 'dispatched',
    'poll', 'polls', 'polling', 'polled',
    'queue', 'queues', 'queuing', 'queued',
    'listen', 'listens', 'listening', 'listened',
    'persist', 'persists', 'persisting', 'persisted',
    'coordinate', 'coordinates', 'coordinating', 'coordinated',
    'communicate', 'communicates', 'communicating',
    'store', 'stores', 'storing', 'stored',
    'route', 'routes', 'routing', 'routed',
  };

  /// Pattern matching introductory phrases that precede lists or steps.
  static final RegExp _continuationIntro = RegExp(
    r'(?::|\b(?:to|such as|including|following|includes|consists of))\s*:?\s*$',
    caseSensitive: false,
  );

  /// Structural definition patterns that introduce components, roles, or mechanics.
  static final RegExp _structuralPatterns = RegExp(
    r'\b(?:is responsible for|responsible for|consists of|serves as|functions as|acts as|used for|used to|defined as|composed of|interacts with|communicates with)\b',
    caseSensitive: false,
  );

  /// Book navigation, section markers, or figure labels that repeat terms without technical mechanisms.
  static final RegExp _metaHeadingPattern = RegExp(
    r'^(?:\d+\.\d+|chapter\s+\d+|back in chapter|in chapter|as shown in figure|figure\s+\d+\.\d+)',
    caseSensitive: false,
  );

  /// Keep the header plus the sentences that best match the question.
  /// Cuts prefill: chunks over [maxChars] shrink to their best sentences.
  ///
  /// Improvements:
  /// - [maxChars] raised to 1100 to preserve complete multi-component architectures.
  /// - Action-verb bonus (+2) so mechanistic sentences score even when the
  ///   entity name is absent (entity-only queries like "Explain Jenkins").
  /// - Structural bonus (+2) for sentences defining components, roles, or mechanics.
  /// - Meta-heading penalty (-2) so chapter intros don't crowd out technical mechanisms.
  /// - Continuation rule: if a kept sentence ends with ":", "to", "such as",
  ///   "including" or "following", keep the next 2-4 fragments/list items.
  /// - Neighbor window: also keep adjacent sentences so surrounding context
  ///   is not lost.
  static String compressChunk(
    String chunk,
    String question, {
    int maxSentences = 5,
    int maxChars = 1100,
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

    // Score each sentence: term overlap + verb bonus + structural bonus + meta penalty
    final scores = <int>[];
    for (var i = 0; i < sentences.length; i++) {
      final sLower = sentences[i].toLowerCase();
      final termOverlap = _terms(sentences[i]).where(q.contains).length;
      final verbBonus = _actionVerbs.any((v) => sLower.contains(v)) ? 2 : 0;
      final structBonus = _structuralPatterns.hasMatch(sentences[i]) ? 2 : 0;
      final metaPenalty = _metaHeadingPattern.hasMatch(sentences[i]) ? -2 : 0;
      scores.add(termOverlap + verbBonus + structBonus + metaPenalty);
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
    String? scope,
  }) {
    final b = StringBuffer();
    b.writeln(
      'You are the generation engine for NotebookPRO, a study assistant for '
      'Master-level data science coursework. Turn the retrieved textbook '
      'excerpts into accurate, well-structured study material.',
    );
    b.writeln();
    b.writeln(
      'GROUNDING: Use ONLY information that appears in the provided <source_material> documents. '
      'Never use outside knowledge and never guess. Each document is uniquely identified by its index '
      '(e.g., <document index="1">). If the context does not cover part of the question, leave that part '
      'out instead of filling it in. Ignore excerpts that use the term in a different sense, such as a '
      'person\'s name (e.g., author names or academic citations) or an index/page listing. '
      'Only explain the actual technology or concept asked about.',
    );
    if (scope != null && scope.trim().isNotEmpty) {
      b.writeln(
        '- STRICT SCOPE CONFINEMENT: The student query specifies the scope "${scope.trim()}". '
        'Restrict the entire response strictly to "${scope.trim()}" dimensions. '
        'Do NOT include off-scope topics (e.g. if the scope is storage, do NOT discuss transaction managers, query orchestration, or governance). '
        'Every bullet or point must directly address "${scope.trim()}".',
      );
    }
    b.writeln(
      'TECHNICAL ACCURACY & PRECISION:\n'
      '- INDEPENDENT & OBJECTIVE DEFINITION: Define the subject itself first according to its standalone purpose, essential characteristics, and core capability. '
      'Do NOT define it merely as a subordinate tier, precursor, or component of a downstream derivative technology. '
      'Keep definitions objective, functional, and neutral; never adopt cynical, informal, or subjective characterizations from authors.\n'
      '- PRECISE OPERATIONAL MECHANICS: Faithfully distinguish when operations occur (e.g., read time vs write time, compile time vs run time, training vs inference). '
      'Never claim that structural validation or schema constraints guarantee underlying semantic truth or factual correctness of data unless explicitly stated.\n'
      '- MECHANISTIC ACCURACY: Describe component interactions accurately. Format or protocol conversions require parsing, translation, or execution by intermediate engines—do not characterize transformations as zero-cost or automatic unless supported by evidence.\n'
      '- TEMPORAL & ARCHITECTURAL SCOPING: When citing limitations, performance bottlenecks, or missing capabilities, explicitly scope them to the specific architecture or historical baseline described in the text, noting where modern standards, extensions, or paradigms address them.\n'
      '- BALANCED & NUANCED COMPARISONS: When contrasting entities, avoid oversimplified binaries or superficial generalizations. Contrast core paradigms across concrete technical dimensions (e.g., Architecture, Workloads, Data/State Handling, Scalability, Governance/Trade-offs) with explicit architectural reasons rather than vague adjectives (e.g., detail decoupled resource scaling vs monolithic cluster sizing, indexing and ingestion overhead, or memory constraints).',
    );
    if (validYears(chunks).length >= 2) {
      b.writeln(
        'SOURCE AGE: Excerpts carry a year. If sources differ, present the '
        'newest as current practice and older ones as background.',
      );
    }
    if (_hasEraEvidence(chunks.join('\n').toLowerCase())) {
      b.writeln(
        '- Keep time and scope qualifiers from the excerpts ("traditionally", '
        '"historically", "in early versions", "modern", "in some cases"). Never '
        'present a historical limitation as a current one. If the excerpts '
        'describe both an older and a newer form, cover both and label each.',
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
      '(e.g., Ingestion -> Processing -> Storage, or Trigger -> Build -> Deploy), '
      'explaining how stages interact instead of repeating isolated definitions.',
    );
    b.writeln(
      '- For comparison questions (differences, vs, compare): explicitly compare both '
      'entities across concrete technical dimensions (e.g., Architecture, Workloads, '
      'Data Handling, Scaling, Governance). Each bullet under "### Key Points" must represent a '
      'technical comparison dimension and contrast how both entities handle that dimension '
      '(e.g., "- **Schema Handling**: Entity A enforces validation before storage, whereas Entity B interprets structure upon reading [1, 2]."). '
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
      'CITATIONS: End every factual sentence or bullet with its corresponding document '
      'index in brackets: [n] or [n, m], matching the index attribute in <document index="n">. '
      'Numbers only; never a year, filename or the word "Source". Uncited sentences will be removed.',
    );
    if (uc == AnswerUseCase.comparison) {
      b.writeln();
      b.writeln('COMPARISON GUIDELINES:');
      b.writeln('- Use EXACTLY two sections: "### Overview" and "### Key Differences". Never invent extra headings or section titles.');
      b.writeln('- Overview: 1-2 authoritative sentences stating the fundamental architectural distinction between both entities. Do NOT repeat definitions or list specific bullet points in the overview.');
      b.writeln('- Key Differences: 4-6 substantive comparison bullets, each beginning with a bold technical dimension (e.g., "- **Storage Media & Scaling**: ...", "- **Schema & Format Handling**: ...", "- **Cost & Efficiency Model**: ...").');
      b.writeln('- Dual-Sided Contrast: Every bullet MUST explicitly contrast BOTH entities across that dimension, with citations matching the exact supporting sources [n].');
      b.writeln('- Scope Adherence: If the question includes a scope limiter (e.g. "in terms of data storage"), restrict all bullets strictly to that scope. Do not include transactions, consistency, or unrelated dimensions.');
      b.writeln('- No Speculative Causation: Do not invent causal explanations ("due to", "because") unless the cited text explicitly states that cause-and-effect relationship.');
    } else if (uc == AnswerUseCase.explanation) {
      b.writeln();
      b.writeln('STRUCTURE & FORMATTING GUIDELINES:');
      b.writeln('- DYNAMIC THEMATIC SECTIONS: Organize the response using logical ### headings driven strictly by the core themes and dimensions present in the evidence:');
      b.writeln('  * Begin with an authoritative, standalone definition or core concept under "### Definition" or "### Core Concept".');
      b.writeln('  * Structure subsequent sections around the substantive dimensions substantiated in the text (e.g., Architecture & Components, Operational Mechanics, Specifications/Protocols, or Execution Lifecycle).');
      b.writeln('  * Focus substantive sections on core architecture, component responsibilities, and operational mechanics (e.g., "### System Architecture & Components", "### Execution Workflow & Mechanics"). Include "### Limitations & Bottlenecks" only when the evidence directly discusses bottlenecks, constraints, or failure modes. Only include version history or evolutionary milestones if the user query explicitly requests evolution or historical development.');
      b.writeln('- ARCHITECTURAL ROLES & INTERACTIONS: When explaining system architecture, explicitly identify each core component named in the evidence (e.g., schedulers, worker processes, execution engines, databases/state stores, API/web servers) and explain its specific operational responsibility and how components interact. Do not substitute high-level capabilities (e.g., task definitions or event triggers) for component mechanics.');
      b.writeln('- TECHNICAL PRECISION OVER METAPHORS: Use precise engineering terminology. Never use promotional author metaphors (e.g., do not call orchestrators "conductors" or describe outputs as "harmonious"). State exact operational roles, protocols, and data/state flows objectively.');
      b.writeln('- EVIDENCE-PROPORTIONAL DEPTH: Synthesize a fact-dense explanation proportional to the available evidence (typically 180-450 words when context is rich). Do not pad sections with redundant phrasing or invent ungrounded details to satisfy arbitrary length.');
      b.writeln('- SUBSTANTIVE CONTENT: Each section must contain substantive, fact-dense explanations using paragraphs or bullets with **bold key terms** (e.g., "- **<Key Concept>**: <substantive technical explanation with operational mechanisms> [n]."). Only include a section heading if the retrieved evidence contains substantive material to support it. Never emit empty sections or solitary one-line stubs.');
    }
    return b.toString();
  }

  static String _task(AnswerUseCase uc) => switch (uc) {
        AnswerUseCase.comparison =>
          'TASK: Provide a structured, rigorous academic technical comparison synthesized strictly from the context.\n'
              '- REQUIRED STRUCTURE: Organize the answer into exactly two sections:\n'
              '  ### Overview\n'
              '  1-2 authoritative, concise sentences introducing the fundamental architectural distinction between both entities. '
              'Do not repeat definitions or list specific points that belong in the bullets below.\n'
              '  ### Key Differences\n'
              '  4-6 substantive, fact-dense comparison bullets. Each bullet MUST strictly follow this format:\n'
              '  - **<Comparison Dimension>**: <Direct contrast explaining how Entity A handles this dimension vs how Entity B handles it> [n].\n'
              '- STRICT SCOPE CONFINEMENT: If the question includes a scope limiter (e.g., "in terms of data storage", "regarding performance"), every bullet MUST directly address that requested scope. '
              'Do NOT include off-scope topics (e.g., if the scope is storage, do NOT discuss transaction managers, query orchestration, or governance).\n'
              '- DUAL-SIDED CONTRASTS: Every bullet must explicitly contrast BOTH entities across the dimension. Never discuss only one entity in isolation.\n'
              '- NO INVENTED SUBHEADINGS: Do not create invented section headings beyond "### Overview" and "### Key Differences".\n'
              '- NO REPETITION: Do not repeat concepts from the Overview in the Key Differences bullets.\n'
              '- NO SPECULATIVE CAUSATION: Do not invent causal explanations ("due to", "because") unless the cited text explicitly states that specific cause-and-effect relationship.\n'
              '- End every factual sentence or bullet with its citation [n] or [n, m].\n',
        AnswerUseCase.explanation =>
          'TASK: Provide a comprehensive academic explanation synthesized from the context.\n'
              '- DEPTH EXPECTATIONS: For in-depth questions ("Explain ... in detail"), deliver thorough, rigorous coverage (typically 180-450 words depending on available evidence). '
              'Address definition, architecture, core internal components (roles and interactions), operational mechanics, execution workflows, and trade-offs/limitations—where supported by the context. Do not allocate sections or bullets to version milestones or release history unless the question explicitly asks about evolution or versions.\n'
              '- EVIDENCE SYNTHESIS: Synthesize all key technical concepts present in the retrieved excerpts into coherent, thematic explanations rather than isolated single bullets.\n'
              '- INDEPENDENT & OBJECTIVE DEFINITION: Start with "### Definition": 1-2 objective, authoritative sentences explaining what the subject IS and what core capability it provides independently. '
              'Do not define the primary subject as merely a subordinate tier of a newer derivative technology. Do not adopt cynical or informal characterizations. Reserve limitations and governance challenges strictly for later sections.\n'
              '- SUBSTANTIVE EXPLANATION: Each bullet or paragraph must introduce distinct technical mechanisms supported by the excerpts. Avoid repeating definitions with rephrased words.\n'
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

  /// Formats raw or prepared chunks into structured XML `<source_material>` containers.
  /// Smaller on-device models follow XML boundaries much more reliably than flat text.
  static String formatChunksToXml(List<String> chunks) {
    if (chunks.isEmpty) return '';
    final b = StringBuffer();
    b.writeln('<source_material>');

    final sectionRegex = RegExp(
      r'^\[Section:\s*([^\]\n]+)\]\s*\n?([\s\S]*)$',
      caseSensitive: false,
    );

    for (int i = 0; i < chunks.length; i++) {
      final raw = chunks[i].trim();
      if (raw.isEmpty) continue;

      int index = i + 1;
      String source = '';
      String facet = '';
      String section = '';
      String body = raw;

      final nl = raw.indexOf('\n');
      final firstLine = nl == -1 ? raw : raw.substring(0, nl);
      final remaining = nl == -1 ? '' : raw.substring(nl + 1).trim();

      final firstLineMatch = RegExp(r'^(?:\[(\d+)\]\s*)?(.+?)(?:\s*\(([^)\n]+)\))?:\s*$').firstMatch(firstLine.trim());
      if (firstLineMatch != null) {
        if (firstLineMatch.group(1) != null) {
          index = int.tryParse(firstLineMatch.group(1)!) ?? (i + 1);
        }
        source = (firstLineMatch.group(2) ?? '').trim();
        facet = (firstLineMatch.group(3) ?? '').trim();
        body = remaining;
      }

      // Check if body starts with [Section: ...]
      final secMatch = sectionRegex.firstMatch(body);
      if (secMatch != null) {
        section = secMatch.group(1)!.trim();
        body = secMatch.group(2)!.trim();
      }

      final attrs = StringBuffer('index="$index"');
      if (source.isNotEmpty) {
        attrs.write(' source="${_escapeXml(source)}"');
      }
      if (facet.isNotEmpty && facet.toLowerCase() != 'general') {
        attrs.write(' facet="${_escapeXml(facet)}"');
      }
      if (section.isNotEmpty) {
        attrs.write(' section="${_escapeXml(section)}"');
      }

      b.writeln('  <document $attrs>');
      b.writeln('    ${body.replaceAll('\n', '\n    ')}');
      b.writeln('  </document>');
    }

    b.write('</source_material>');
    return b.toString();
  }

  static String _escapeXml(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }

  static String buildUserMessage(
    String question,
    List<String> chunks,
    AnswerUseCase uc, {
    String? scope,
  }) {
    final b = StringBuffer();
    if (chunks.isNotEmpty) {
      b.writeln(formatChunksToXml(chunks));
      b.writeln();
    }
    b.writeln("Student's question: $question");
    b.writeln();
    if (scope != null && scope.trim().isNotEmpty) {
      b.writeln('Scope Constraint: The user explicitly specified the scope "${scope.trim()}". Restrict your analysis strictly to "${scope.trim()}" dimensions.');
      b.writeln();
    }
    if (isYesNoQuestion(question)) {
      b.writeln(
        'This is a yes/no question: begin with Yes, No or Partly, then give '
        'the evidence from the context. Statements such as "X lacks Y" or '
        '"X requires Y" answer it.',
      );
      b.writeln();
    }
    b.write(
      'Instructions: Answer ONLY using facts from the <source_material> documents above. '
      'If the context covers only part of the question, answer that part and say what is missing; '
      'say you do not have the information only when the context contains nothing relevant. '
      'Ground every factual claim and cite its document index as [n] or [n, m] matching <document index="n">.',
    );
    final checklist = qualityChecklist(question, uc, chunks);
    if (checklist.isNotEmpty) {
      b.write('\n$checklist');
    }
    return b.toString();
  }

  static final RegExp _yesNoRe = RegExp(
    r'^(does|do|did|is|are|was|were|can|could|should|will|would|has|have|had)\b',
    caseSensitive: false,
  );

  static bool isYesNoQuestion(String question) =>
      _yesNoRe.hasMatch(question.trim());

  /// Domain-neutral retrieval facets for questions where an older and a newer
  /// form of the same thing may both be described.
  static List<String> eraFacets(String topic) => [
        '$topic traditional legacy earlier approach',
        '$topic modern current recent approach',
      ];

  static bool _hasEraEvidence(String ctx) => RegExp(
        r'\b(traditional(?:ly)?|legacy|historically|originally|early (?:systems?|versions?)|older|modern|nowadays|evolved)\b',
      ).hasMatch(ctx);

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
    if (RegExp(r'\b(schema-on-read|schema-on-write|schema enforcement|schema validation)\b').hasMatch(ctx)) {
      items.add('distinguish schema-on-read (structure applied upon reading) from schema-on-write (validation before storage), without claiming schema enforcement guarantees factual truth');
    }
    if (RegExp(r'\b(format conversion|columnar format|transcoding|parquet|orc|avro)\b').hasMatch(ctx)) {
      items.add('qualify that format conversions require execution engines and parsing rather than direct zero-cost transcoding');
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
