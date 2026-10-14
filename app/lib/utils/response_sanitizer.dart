import 'dart:math' as math;

class ResponseSanitizer {
  static const String endMarker = "<<END_OF_ANSWER>>";

  /// Normalizes model LaTeX delimiters for Flutter Markdown Math parsers.
  /// Converts \[ ... \] to $$...$$ and \( ... \) to $...$.
  /// BUG FIX: Trims whitespace ONLY inside delimiters ($ x $ -> $x$),
  /// preserving whitespace preceding/following the delimiter ("and $x$" remains "and $x$").
  static String normalizeMathDelimiters(String text) {
    if (text.isEmpty) return "";

    // 1. Convert block math \[ ... \] to $$...$$
    String normalized = text.replaceAllMapped(
      RegExp(r'\\\[([\s\S]*?)\\\]'),
      (m) => '\$\$${m.group(1)!.trim()}\$\$',
    );

    // 2. Convert inline math \( ... \) to $...$
    normalized = normalized.replaceAllMapped(
      RegExp(r'\\\(([^\n]*?)\\\)'),
      (m) => '\$${m.group(1)!.trim()}\$',
    );

    // 3. Trim interior whitespace of block math $$ ... $$ without touching surrounding text
    normalized = normalized.replaceAllMapped(
      RegExp(r'\$\$\s+([\s\S]*?)\$\$'),
      (m) => '\$\$${m.group(1)}\$\$',
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'\$\$([\s\S]*?)\s+\$\$'),
      (m) => '\$\$${m.group(1)}\$\$',
    );

    // 4. Trim interior whitespace of inline math $ ... $ without touching surrounding text
    normalized = normalized.replaceAllMapped(
      RegExp(r'\$\s+([^$\n]+?)\$'),
      (m) => '\$${m.group(1)}\$',
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'\$([^$\n]+?)\s+\$'),
      (m) => '\$${m.group(1)}\$',
    );

    return normalized;
  }

  /// Wraps plain-text metric equations in LaTeX delimiters when missing.
  /// BUG FIX: Restricts acronym repair strictly to known data science / NLP metric names
  /// (e.g. asMAE -> as MAE), avoiding breakage on real words like gRPC, kNN, macOS, iOS.
  static String normalizeFormulaEquations(String text) {
    if (text.isEmpty) return "";

    final metricAcronyms = [
      'MAE', 'RMSE', 'MAPE', 'MASE', 'MSE', 'R2', r'R\^2',
      'BLEU', 'METEOR', 'BERTScore', r'ROUGE(?:-[A-Za-z0-9]+)?', 'LCS'
    ];
    final metricPatternStr = metricAcronyms.join('|');

    final metricEq = RegExp(
      r'\b(' + metricPatternStr + r')\s*=\s*([^$\n]+?)(?=(?:\s*(?:,?\s*where\b|[.;]|$)))',
      caseSensitive: false,
    );
    final formulaLabel = RegExp(
      r'(\bformula\s*:\s*)([^$\n]*?=[^$\n]+?)(?=(?:\s*(?:[.;]|$)))',
      caseSensitive: false,
    );
    final acronymSpacing = RegExp('([a-z])($metricPatternStr)\\b');

    final outLines = <String>[];
    for (final rawLine in text.split('\n')) {
      var line = rawLine;
      if (line.contains('\$') || line.contains('|')) {
        outLines.add(line);
        continue;
      }

      // Repair missing space around known metric acronyms only (e.g. asMAE -> as MAE)
      line = line.replaceAllMapped(acronymSpacing, (m) => '${m.group(1)} ${m.group(2)}');

      line = line.replaceAllMapped(formulaLabel, (m) {
        final prefix = m.group(1)!;
        final expr = m.group(2)!.trim();
        return '$prefix\$$expr\$';
      });

      line = line.replaceAllMapped(metricEq, (m) {
        final metric = m.group(1)!.trim();
        final expr = m.group(2)!.trim();
        return '\$$metric = $expr\$';
      });

      outLines.add(line);
    }

    return outLines.join('\n');
  }

  /// Expands single-line compact table blobs into one row per line.
  static List<String> _expandCompactTableLine(String line) {
    if (line.split('|').length < 8 || !line.contains('| |')) {
      return [line];
    }

    final tokens = line.split('|').map((t) => t.trim()).toList();
    final rows = <List<String>>[];
    var current = <String>[];

    for (final token in tokens) {
      if (token.isEmpty) {
        if (current.length >= 2) {
          rows.add(current);
        }
        current = [];
        continue;
      }
      current.add(token);
    }

    if (current.length >= 2) {
      rows.add(current);
    }

    if (rows.length < 2) {
      return [line];
    }

    int colCount = 0;
    for (final r in rows) {
      if (r.length > colCount) colCount = r.length;
    }

    return rows.map((r) {
      final cells = List<String>.from(r);
      while (cells.length < colCount) {
        cells.add('');
      }
      return '| ${cells.join(' | ')} |';
    }).toList();
  }

  static bool isMarkdownTableRow(String line) {
    if (!line.contains('|')) return false;
    final trimmed = line.trim();
    if (!trimmed.startsWith('|') && !trimmed.endsWith('|')) return false;
    final cells = trimmed.split('|').map((c) => c.trim()).where((c) => c.isNotEmpty).toList();
    return cells.isNotEmpty;
  }

  static bool isMarkdownTableSeparator(String line) {
    if (!line.contains('|')) return false;
    final trimmed = line.trim();
    final cells = trimmed.split('|').map((c) => c.replaceAll(' ', '')).where((c) => c.isNotEmpty).toList();
    if (cells.isEmpty) return false;
    return cells.every((c) => RegExp(r'^:?-{2,}:?$').hasMatch(c));
  }

  /// Repairs malformed markdown tables (e.g. missing separator rows or compact inline rows).
  static String repairMarkdownTables(String text) {
    if (text.isEmpty || !text.contains('|')) return text;

    final expandedLines = <String>[];
    for (final rawLine in text.split('\n')) {
      final stripped = rawLine.trim();
      if (stripped.isEmpty) {
        expandedLines.add('');
        continue;
      }
      expandedLines.addAll(_expandCompactTableLine(rawLine));
    }

    final repaired = <String>[];
    int i = 0;
    while (i < expandedLines.length) {
      final line = expandedLines[i].trim();

      if (!isMarkdownTableRow(line)) {
        repaired.add(expandedLines[i]);
        i++;
        continue;
      }

      final block = <String>[];
      while (i < expandedLines.length) {
        final probe = expandedLines[i].trim();
        if (probe.isEmpty) break;
        if (!isMarkdownTableRow(probe) && !isMarkdownTableSeparator(probe)) break;
        block.add(expandedLines[i]);
        i++;
      }

      if (block.length >= 2 &&
          isMarkdownTableRow(block[0]) &&
          !isMarkdownTableSeparator(block[1]) &&
          isMarkdownTableRow(block[1])) {
        final colCount = math.max(2, block[0].split('|').where((c) => c.trim().isNotEmpty).length);
        final separator = '| ${List.filled(colCount, '---').join(' | ')} |';
        block.insert(1, separator);
      }

      repaired.addAll(block);
      if (i < expandedLines.length && expandedLines[i].trim().isEmpty) {
        repaired.add('');
        i++;
      }
    }

    return repaired.join('\n');
  }

  /// Sanitizes assistant output, stripping reasoning tags and OCR numbering garbage.
  /// BUG FIX: Uses trimRight() to preserve leading whitespace / nested bullet hierarchy.
  static String sanitizeResponse(String text) {
    if (text.isEmpty) return "";

    var cleaned = text.replaceAll(endMarker, '').trimRight();
    cleaned = normalizeMathDelimiters(cleaned);
    cleaned = normalizeFormulaEquations(cleaned);

    // Strip internal reasoning wrappers
    cleaned = cleaned.replaceAll(RegExp(r'<think>[\s\S]*?</think>', caseSensitive: false), '');
    cleaned = cleaned.replaceAll(RegExp(r'<\|begin_of_thought\|>[\s\S]*?<\|end_of_thought\|>', caseSensitive: false), '');

    // Strip unexpanded citation placeholders like [n], [n, m], [placeholder], [cite]
    cleaned = cleaned.replaceAll(
      RegExp(r'\[\s*(?:n|x|placeholder|cite|citation\s*needed)(?:\s*,\s*(?:n|x|placeholder|cite))*\s*\]', caseSensitive: false),
      '',
    );

    final cleanedLines = <String>[];
    for (final rawLine in cleaned.split('\n')) {
      // Preserve leading indentation for nested bullets
      final trimmedRight = rawLine.trimRight();
      final stripped = trimmedRight.trim();
      if (stripped.isEmpty) {
        cleanedLines.add("");
        continue;
      }

      // Guardrail against OCR numbering artifacts (e.g. 1.1.1.1.1.1.1.1)
      if (RegExp(r'(?:\d+\.){7,}\d*').hasMatch(stripped)) continue;

      final compact = stripped.replaceAll(RegExp(r'\s+'), '');
      if (compact.length >= 40 && RegExp(r'^[\d\W_]+$').hasMatch(compact)) continue;

      cleanedLines.add(trimmedRight);
    }

    cleaned = cleanedLines.join('\n');
    cleaned = cleaned.replaceAll(RegExp(r'\n{3,}'), '\n\n').trimRight();
    cleaned = repairMarkdownTables(cleaned);
    return cleaned;
  }

  /// Checks if output terminates abruptly mid-sentence or mid-block.
  static bool looksTruncated(String text) {
    final stripped = text.trim();
    if (stripped.length < 20) return false;
    if (stripped.contains(endMarker)) return false;

    // Ends cleanly on punctuation or closed blocks
    if (stripped.endsWith('.') ||
        stripped.endsWith('!') ||
        stripped.endsWith('?') ||
        stripped.endsWith(']') ||
        stripped.endsWith(')') ||
        stripped.endsWith('"') ||
        stripped.endsWith("```")) {
      return (stripped.split('**').length % 2 == 0) || (stripped.split('```').length % 2 == 0);
    }

    // Ends on alphanumeric or dangling words
    if (RegExp(r'[a-zA-Z0-9]$').hasMatch(stripped)) return true;
    if (stripped.split('**').length % 2 == 0 || stripped.split('```').length % 2 == 0) return true;

    const dangling = [
      ' and', ' or', ' to', ' of', ' for', ' with', ' by', ' in', ' is', ' are', ' a', ' an', ' the', ' that', ' which'
    ];
    final lowered = stripped.toLowerCase();
    return dangling.any((w) => lowered.endsWith(w)) || stripped.endsWith(':') || stripped.endsWith('-') || stripped.endsWith(',');
  }

  /// Trims text back to the last complete sentence, bullet point, or table row.
  /// Zero-latency, free cutoff recovery.
  static String trimToLastCompleteUnit(String text) {
    if (!looksTruncated(text)) return text;

    final lines = text.split('\n');

    for (int i = lines.length - 1; i >= 0; i--) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      // Table row is complete if it ends with |
      if (line.startsWith('|') && line.endsWith('|')) {
        return lines.take(i + 1).join('\n');
      }

      // Heading is complete
      if (RegExp(r'^#{1,6}\s+').hasMatch(line)) {
        return lines.take(i + 1).join('\n');
      }

      // Check terminal punctuation of whole line
      if (line.endsWith('.') || line.endsWith('!') || line.endsWith('?') || line.endsWith('```') || line.endsWith(']')) {
        return lines.take(i + 1).join('\n');
      }

      // If line does not end cleanly, trim back to the last complete sentence within the line
      final lastPeriod = line.lastIndexOf('.');
      final lastExcl = line.lastIndexOf('!');
      final lastQues = line.lastIndexOf('?');
      int lastPunct = lastPeriod;
      if (lastExcl > lastPunct) lastPunct = lastExcl;
      if (lastQues > lastPunct) lastPunct = lastQues;

      if (lastPunct != -1) {
        final completedPortion = line.substring(0, lastPunct + 1).trim();
        final prefixLines = lines.take(i).toList();
        prefixLines.add(completedPortion);
        return prefixLines.join('\n');
      }
    }

    return text;
  }
}

