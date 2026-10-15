import 'dart:math' as math;

/// Post-processing for on-device model output.
///
/// Dart port of the original Python LLMGenerator sanitizers
/// (_sanitize_final_response, _repair_markdown_tables, _looks_truncated, ...),
/// with these deliberate differences:
///  * indentation is preserved (the Python code .strip()s every line, which
///    flattens nested bullets),
///  * whitespace is trimmed only INSIDE $...$ / $$...$$ (the Python code
///    collapses whitespace around every "$", which glues text to inline math),
///  * the "asMAE" -> "as MAE" repair is limited to metric names (the generic
///    ([a-z])([A-Z]{2,}) version breaks gRPC, kNN, macOS, iOS, ...),
///  * truncated answers are trimmed to the last complete sentence instead of
///    being regenerated (a continuation call would cost a full extra prefill).
///
/// Usage in AppState, after the stream finishes:
///   final clean = AnswerSanitizer.finalize(raw,
///       hitTokenLimit: LocalLlmService.lastHitTokenLimit);
/// then run the citation enforcer and skip lines where
/// AnswerSanitizer.isMathOrTableLine(line) is true, so equations and tables
/// are not deleted for lacking lexical overlap with the chunks.
class AnswerSanitizer {
  AnswerSanitizer._();

  // ------------------------------------------------------------------ public

  static String finalize(
    String raw, {
    bool hitTokenLimit = false,
    bool trimTruncated = false,
  }) {
    if (raw.trim().isEmpty) return '';

    var text = raw
        .replaceAll(_thinkBlock, '')
        .replaceAll(_thoughtBlock, '')
        .replaceAll(_specialToken, '');

    text = stripAcademicNote(text);
    text = normalizeMathDelimiters(text);
    text = normalizeFormulaEquations(text);
    text = _dropArtifactLines(text);
    text = correctSchemaOverstatements(text);
    text = correctTechnicalContradictions(text);
    text = sanitizeInformalTropes(text);
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    text = repairMarkdownTables(text);

    if (trimTruncated && (hitTokenLimit || looksTruncated(text))) {
      text = trimToCompleteUnit(text);
    }
    return text;
  }

  /// True for table rows/separators and lines that are essentially a formula.
  static bool isMathOrTableLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    if (t.startsWith(r'$$') || t.endsWith(r'$$')) return true;
    if (_isTableSeparator(t) || _isTableRow(t)) return true;
    if (RegExp(r'\$[^$\n]+\$').hasMatch(t)) {
      final rest = t
          .replaceAll(RegExp(r'\$[^$\n]+\$'), '')
          .replaceAll(RegExp(r'^[-*\d.)\s]+'), '')
          .replaceAll(RegExp(r'\*\*[^*]+\*\*:?'), '')
          .trim();
      return rest.length < 12;
    }
    return false;
  }

  static String stripAcademicNote(String text) {
    const marker = '### Academic Note:';
    final idx = text.indexOf(marker);
    return idx == -1 ? text.trim() : text.substring(0, idx).trim();
  }

  static String normalizeMathDelimiters(String text) {
    if (text.isEmpty) return '';
    var out = text.replaceAllMapped(
      RegExp(r'\\\[([\s\S]*?)\\\]'),
      (m) => r'$$' + m.group(1)!.trim() + r'$$',
    );
    out = out.replaceAllMapped(
      RegExp(r'\\\(([^\n]*?)\\\)'),
      (m) => r'$' + m.group(1)!.trim() + r'$',
    );
    // Trim padding inside delimiters only.
    out = out.replaceAllMapped(
      RegExp(r'\$\$\s*([\s\S]+?)\s*\$\$'),
      (m) => r'$$' + m.group(1)! + r'$$',
    );
    // Inline "$ x $" -> "$x$". Padding is required on BOTH sides, the opening
    // "$" must not follow a word character and the closing "$" must not be
    // followed by one; otherwise the closing "$" of one formula would be
    // mistaken for the opening "$" of the next and eat the spaces around it.
    out = out.replaceAllMapped(
      RegExp(r'(?<![\w$])\$[ \t]+([^$\n]+?)[ \t]+\$(?![\w$])'),
      (m) => r'$' + m.group(1)! + r'$',
    );
    return out;
  }

  static String normalizeFormulaEquations(String text) {
    if (text.isEmpty) return '';
    final out = <String>[];
    for (final rawLine in text.split('\n')) {
      var line = rawLine;
      if (line.contains(r'$') || line.contains('|')) {
        out.add(line);
        continue;
      }
      line = line.replaceAllMapped(_metricGlue, (m) => '${m[1]} ${m[2]}');
      line = line.replaceAllMapped(
        _formulaLabel,
        (m) => '${m[1]}\$${m[2]!.trim()}\$',
      );
      if (!line.contains(r'$')) {
        line = line.replaceAllMapped(
          _metricEq,
          (m) => '\$${m[1]} = ${m[2]!.trim()}\$',
        );
      }
      out.add(line);
    }
    return out.join('\n');
  }

  static String repairMarkdownTables(String text) {
    if (text.isEmpty || !text.contains('|')) return text;

    final expanded = <String>[];
    for (final raw in text.split('\n')) {
      final s = raw.trim();
      if (s.isEmpty) {
        expanded.add('');
        continue;
      }
      final parts = _expandCompactTableLine(s);
      if (parts.length == 1 && parts.first == s) {
        expanded.add(raw); // keep original indentation
      } else {
        expanded.addAll(parts);
      }
    }

    final repaired = <String>[];
    var i = 0;
    while (i < expanded.length) {
      final line = expanded[i].trim();
      if (!_isTableRow(line)) {
        repaired.add(expanded[i]);
        i++;
        continue;
      }
      final block = <String>[];
      while (i < expanded.length) {
        final probe = expanded[i].trim();
        if (probe.isEmpty) break;
        if (!(_isTableRow(probe) || _isTableSeparator(probe))) break;
        block.add(probe);
        i++;
      }
      if (block.length >= 2 &&
          _isTableRow(block[0]) &&
          !_isTableSeparator(block[1]) &&
          _isTableRow(block[1])) {
        final cols = math.max(2, _splitCells(block[0]).length);
        block.insert(1, '| ${List.filled(cols, '---').join(' | ')} |');
      }
      repaired.addAll(block);
      if (i < expanded.length && expanded[i].trim().isEmpty) {
        repaired.add('');
        i++;
      }
    }
    return repaired.join('\n');
  }

  /// Heuristic for cut-off output (port of _looks_truncated).
  static bool looksTruncated(String text) {
    final s = text.trimRight();
    if (s.length < 160) return false;

    final unbalanced =
        (s.split('**').length - 1) % 2 != 0 || (s.split('```').length - 1) % 2 != 0;

    const endings = ['.', '!', '?', ']', ')', '"', "'", '```'];
    if (endings.any((e) => s.endsWith(e))) return unbalanced;
    if (RegExp(r'[A-Za-z0-9]$').hasMatch(s)) return true;
    if (unbalanced) return true;

    final lowered = s.toLowerCase();
    const dangling = [
      ' and', ' or', ' to', ' of', ' for', ' with', ' by', ' in',
      ' is', ' are', ' a', ' an', ' the',
    ];
    return dangling.any((d) => lowered.endsWith(d)) ||
        const [':', '-', '*', ',', ';'].any((e) => s.endsWith(e));
  }

  /// Cut a truncated answer back to its last complete sentence or bullet.
  static String trimToCompleteUnit(String text) {
    final original = text.trimRight();
    final lines = original.split('\n');
    while (lines.isNotEmpty) {
      final last = lines.last.trimRight();
      if (last.trim().isEmpty || last.trimLeft().startsWith('#')) {
        lines.removeLast();
        continue;
      }
      if (_cleanEnd.hasMatch(last)) break;
      final m = _lastSentence.firstMatch(last);
      if (m != null && m.group(0)!.trim().length > 20) {
        lines[lines.length - 1] = m.group(0)!;
        break;
      }
      lines.removeLast();
    }
    final result = lines.join('\n').trimRight();
    return result.isEmpty ? original : result;
  }

  // ----------------------------------------------------------------- private

  static final RegExp _thinkBlock =
      RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false);
  static final RegExp _thoughtBlock = RegExp(
    r'<\|begin_of_thought\|>[\s\S]*?<\|end_of_thought\|>',
    caseSensitive: false,
  );
  static final RegExp _specialToken = RegExp(
    r'<\|[a-z0-9_]+\|>|</?(?:start_of_turn|end_of_turn|bos|eos)>',
    caseSensitive: false,
  );
  static final RegExp _metricGlue = RegExp(
    r'([a-z])(MAE|RMSE|MAPE|MASE|MSE|BLEU|METEOR|BERTScore|ROUGE)',
  );
  static final RegExp _formulaLabel = RegExp(
    r'(\bformula\s*:\s*)([^$\n]*?=[^$\n]+?)(?=(?:\s*(?:[.;]|$)))',
    caseSensitive: false,
  );
  static final RegExp _metricEq = RegExp(
    r'\b(MAE|RMSE|MAPE|MASE|MSE|R2|R\^2|BLEU|METEOR|BERTScore|ROUGE(?:-[A-Za-z0-9]+)?)\s*=\s*([^$\n]+?)(?=(?:\s*(?:,?\s*where\b|[.;]|$)))',
    caseSensitive: false,
  );
  static final RegExp _cleanEnd = RegExp(r'[.!?\]\)`]\s*$');
  static final RegExp _lastSentence =
      RegExp(r'^.*[.!?](?:\s*\[\d+(?:\s*,\s*\d+)*\])?(?=\s|$)');

  static String _dropArtifactLines(String text) {
    final out = <String>[];
    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        out.add('');
        continue;
      }
      // OCR-style numbering artifacts such as 1.1.1.1.1.1.1.1.
      if (RegExp(r'(?:\d+\.){8,}\d*').hasMatch(line)) continue;
      final compact = line.replaceAll(RegExp(r'\s+'), '');
      if (compact.length >= 40 && RegExp(r'^[\d\W_]+$').hasMatch(compact)) {
        continue;
      }
      out.add(line);
    }
    return out.join('\n');
  }

  static List<String> _splitCells(String line) {
    var s = line.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|')) s = s.substring(0, s.length - 1);
    return s.split('|').map((c) => c.trim()).toList();
  }

  static bool _isTableSeparator(String line) {
    if (!line.contains('|')) return false;
    final cells = _splitCells(line);
    if (cells.length < 2) return false;
    final sep = RegExp(r'^:?-{3,}:?$');
    return cells.every((c) => sep.hasMatch(c.replaceAll(' ', '')));
  }

  static bool _isTableRow(String line) {
    if (!line.contains('|')) return false;
    final cells = _splitCells(line);
    return cells.length >= 2 && cells.any((c) => c.isNotEmpty);
  }

  static String _normalizeRow(List<String> cells, int cols) {
    final n = cells.take(cols).map((c) => c.trim()).toList();
    while (n.length < cols) {
      n.add('');
    }
    return '| ${n.join(' | ')} |';
  }

  static List<String> _expandCompactTableLine(String line) {
    if ('|'.allMatches(line).length < 8 || !line.contains('| |')) {
      return [line];
    }
    final tokens = line.split('|').map((t) => t.trim()).toList();
    final rows = <List<String>>[];
    var current = <String>[];
    for (final token in tokens) {
      if (token.isEmpty) {
        if (current.length >= 2) rows.add(current);
        current = <String>[];
        continue;
      }
      current.add(token);
    }
    if (current.length >= 2) rows.add(current);
    if (rows.length < 2) return [line];
    final cols = rows.map((r) => r.length).reduce(math.max);
    return rows.map((r) => _normalizeRow(r, cols)).toList();
  }

  /// Corrects overstatements claiming schema enforcement guarantees semantic data correctness.
  static String correctSchemaOverstatements(String text) {
    if (text.isEmpty) return text;
    var out = text;
    out = out.replaceAll(
      RegExp(r'\bto\s+(?:guarantee|ensure)\s+(?:complete\s+|absolute\s+)?data\s+correctness\b', caseSensitive: false),
      'to enforce structural schema constraints',
    );
    out = out.replaceAll(
      RegExp(r'\b(?:guarantees?|ensures?)\s+(?:complete\s+|absolute\s+)?data\s+correctness\b', caseSensitive: false),
      'enforces structural schema constraints',
    );
    out = out.replaceAll(
      RegExp(r'\bto\s+enforces\b', caseSensitive: false),
      'to enforce',
    );
    out = out.replaceAll(
      RegExp(r'\b(?:guarantees?|ensures?)\s+(?:the\s+)?(?:semantic\s+)?accuracy\s+of\s+(?:the\s+)?data\b', caseSensitive: false),
      'validates data against defined schema constraints',
    );
    out = out.replaceAll(
      RegExp(r'\bensures?\s+(?:that\s+)?(?:the\s+)?data\s+is\s+(?:always\s+)?correct\b', caseSensitive: false),
      'ensures data conforms to defined schema constraints',
    );
    out = out.replaceAll(
      RegExp(r'\bguaranteeing\s+(?:that\s+)?(?:the\s+)?data\s+is\s+correct\b', caseSensitive: false),
      'enforcing structural conformity',
    );
    out = out.replaceAll(
      RegExp(r'\bguarantees?\s+(?:data\s+)?validity\s+and\s+correctness\b', caseSensitive: false),
      'enforces structural validity and schema constraints',
    );
    return out;
  }

  /// Corrects common technical contradictions or inverted concepts.
  static String correctTechnicalContradictions(String text) {
    if (text.isEmpty) return text;
    var out = text;

    // Correct schema-on-read write attribution:
    // With schema-on-read, the structure of the data is interpreted when it is read,
    // rather than being fully enforced before storage.
    out = out.replaceAll(
      RegExp(r'\b(?:the\s+)?schema\s+is\s+(?:dynamically\s+)?created\s+when\s+data\s+is\s+written\b', caseSensitive: false),
      'the structure is interpreted when data is read rather than enforced before storage',
    );
    out = out.replaceAll(
      RegExp(r'\b(?:the\s+)?schema\s+is\s+(?:dynamically\s+)?applied\s+when\s+data\s+is\s+written\b', caseSensitive: false),
      'the structure is interpreted when data is read rather than enforced before storage',
    );
    out = out.replaceAll(
      RegExp(r'\bschema-on-read\b[^\.\n]*?\bwhen\s+data\s+is\s+written\b', caseSensitive: false),
      'schema-on-read, where structure is interpreted when data is read rather than enforced before storage',
    );

    // Correct overbroad format transcoding claims:
    // Conversion between columnar and record formats involves schema mapping and serialization,
    // not direct transcoding without processing.
    out = out.replaceAll(
      RegExp(r'\bdirectly\s+transcoded\s+(?:between|across)\s+formats(?:\s+without\s+processing)?\b', caseSensitive: false),
      'converted across formats using schema mapping and processing engines',
    );
    out = out.replaceAll(
      RegExp(r'\btranscoded\s+(?:between|across)\s+formats\s+without\s+processing\b', caseSensitive: false),
      'converted across formats using schema mapping and processing engines',
    );
    out = out.replaceAll(
      RegExp(r'\btranscoded\s+without\s+processing\b', caseSensitive: false),
      'converted using schema mapping and serialization',
    );

    // Neutralize definitions subordinating data lake to lakehouse:
    // Data lake must be defined as an independent repository, not merely a storage tier of a lakehouse.
    out = out.replaceAll(
      RegExp(r'\b(?:is\s+)?(?:primarily\s+)?(?:designed\s+as\s+|serves\s+as\s+|acts\s+as\s+)(?:the\s+)?(?:bottom\s+|underlying\s+)?storage\s+(?:layer|foundation)\s+of\s+a\s+lakehouse\b', caseSensitive: false),
      'is a centralized repository for storing raw, structured, semistructured, and unstructured data at scale',
    );

    // Correct absolute "schema-less" claim with plural subject agreement:
    // Data lakes are not strictly schema-less; they decouple schema definition from storage and use schema-on-read.
    out = out.replaceAllMapped(
      RegExp(r'\b(lakes?|repositories|systems|stores)\s+remains?\s+schema-less\b', caseSensitive: false),
      (m) {
        final subj = m.group(1)!;
        final verb = subj.toLowerCase().endsWith('s') ? 'employ' : 'employs';
        return '$subj $verb schema-on-read rather than rigid write-time enforcement';
      },
    );
    out = out.replaceAll(
      RegExp(r'\bdata\s+lakes?\s+(?:is|are|remain|remains)\s+(?:strictly\s+)?schema-less\b', caseSensitive: false),
      'data lakes employ schema-on-read',
    );
    out = out.replaceAll(
      RegExp(r'\bstrictly\s+schema-less\b', caseSensitive: false),
      'schema-flexible, employing schema-on-read',
    );
    out = out.replaceAll(
      RegExp(r'\bremain\s+schema-less\b', caseSensitive: false),
      'employ schema-on-read rather than rigid write-time enforcement',
    );
    out = out.replaceAll(
      RegExp(r'\bremains\s+schema-less\b', caseSensitive: false),
      'employs schema-on-read rather than rigid write-time enforcement',
    );

    // Scope transaction and isolation limitations to traditional data lakes:
    out = out.replaceAll(
      RegExp(r'\bdata\s+lakes\s+(?:lack|do\s+not\s+support)\s+(?:ACID\s+)?transactions\b', caseSensitive: false),
      'traditional data lakes lacked native support for ACID transactions and isolation, though modern table formats introduce these capabilities',
    );
    out = out.replaceAll(
      RegExp(r'\blacks?\s+(?:ACID\s+)?transactional\s+isolation\b', caseSensitive: false),
      'traditionally lacked transactional isolation before the advent of modern table formats',
    );

    // Warehouse storage oversimplification (vertically scaled vs decoupled):
    out = out.replaceAll(
      RegExp(r'\bwarehouses\s+(?:only\s+)?rely\s+on\s+local(?:ly)?(?:,\s*|\s+)vertically\s+scaled\s+storage\b', caseSensitive: false),
      'traditional warehouses utilized vertically coupled storage, whereas modern cloud warehouses and lakes decouple storage from compute',
    );

    return out;
  }

  /// Sanitizes informal author characterizations, cynical remarks, or vague colloquialisms.
  static String sanitizeInformalTropes(String text) {
    if (text.isEmpty) return text;
    var out = text;

    // Cynical / informal characterizations (e.g. author's "glorified distributed filesystem")
    out = out.replaceAll(
      RegExp(r'\b(?:a\s+)?glorified\s+distributed\s+filesystem\b', caseSensitive: false),
      'distributed storage system',
    );
    out = out.replaceAllMapped(
      RegExp(r'\b(?:just\s+a\s+|a\s+)?glorified\s+([a-zA-Z\s]+?)\b', caseSensitive: false),
      (m) => '${m.group(1)}',
    );

    // Vague scaling colloquialisms
    out = out.replaceAll(
      RegExp(r'\bgrow\s+unbounded\s+over\s+time\b', caseSensitive: false),
      'accommodate expanding data volumes across distributed storage',
    );

    // Author metaphor: "data swamp", "polluted or toxic"
    out = out.replaceAll(
      RegExp(r'\b(?:become\s+(?:a\s+)?)?(?:data\s+swamp[,\s]*)?(?:polluted\s+or\s+toxic|toxic\s+or\s+polluted)\b', caseSensitive: false),
      'unmanaged and inconsistent due to lack of governance',
    );
    out = out.replaceAll(
      RegExp(r'\bdata\s+swamps?\b', caseSensitive: false),
      'uncataloged and poorly governed data stores',
    );

    // Metaphorical conductor / orchestra characterizations
    out = out.replaceAll(
      RegExp(r'\b(?:acts\s+as\s+(?:an?\s+)?|functions\s+as\s+(?:an?\s+)?)?(?:orchestration\s+|orchestrator\s+)?conductor\s+of\s+an?\s+orchestra\b', caseSensitive: false),
      'workflow orchestrator',
    );
    out = out.replaceAll(
      RegExp(r'\b(?:orchestrator|orchestration)\s+conductor\b', caseSensitive: false),
      'workflow orchestrator',
    );
    out = out.replaceAll(
      RegExp(r'\b(?:acts\s+as\s+(?:an?\s+)?|functions\s+as\s+(?:an?\s+)?)conductor\s+(?:to\s+coordinate|coordinating)\b', caseSensitive: false),
      'workflow orchestrator coordinating',
    );

    // Promotional author fluff: "harmonious results" / "harmonious pipeline"
    out = out.replaceAll(
      RegExp(r'\b(?:to\s+produce\s+|producing\s+|achieving\s+)?(?:a\s+)?harmonious\s+results?\b', caseSensitive: false),
      'reliable pipeline execution',
    );

    // Vague pipeline phrases like "A-to-B operations"
    out = out.replaceAll(
      RegExp(r'\boperators\s+specific\s+to\s+perform\s+actions\s+and\s+A-to-B\s+operations\b', caseSensitive: false),
      'operators designed to execute discrete tasks and data transfers',
    );
    out = out.replaceAll(
      RegExp(r'\bA-to-B\s+operations?\b', caseSensitive: false),
      'end-to-end task executions',
    );

    return out;
  }


}
