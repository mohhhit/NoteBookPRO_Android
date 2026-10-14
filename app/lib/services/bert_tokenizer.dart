import 'dart:io';

class TokenizedPair {
  final List<int> inputIds;
  final List<int> attentionMask;
  final List<int> tokenTypeIds;

  TokenizedPair({
    required this.inputIds,
    required this.attentionMask,
    required this.tokenTypeIds,
  });
}

class BertWordPieceTokenizer {
  final Map<String, int> vocab;
  final int unkTokenId;
  final int clsTokenId;
  final int sepTokenId;
  final int padTokenId;

  BertWordPieceTokenizer({
    required this.vocab,
    this.unkTokenId = 100,
    this.clsTokenId = 101,
    this.sepTokenId = 102,
    this.padTokenId = 0,
  });

  static Future<BertWordPieceTokenizer> fromFile(String vocabPath) async {
    final file = File(vocabPath);
    if (!await file.exists()) {
      throw Exception('Vocab file not found at $vocabPath');
    }

    final lines = await file.readAsLines();
    final vocab = <String, int>{};
    for (int i = 0; i < lines.length; i++) {
      final token = lines[i].trim();
      if (token.isNotEmpty) {
        vocab[token] = i;
      }
    }

    return BertWordPieceTokenizer(
      vocab: vocab,
      unkTokenId: vocab['[UNK]'] ?? 100,
      clsTokenId: vocab['[CLS]'] ?? 101,
      sepTokenId: vocab['[SEP]'] ?? 102,
      padTokenId: vocab['[PAD]'] ?? 0,
    );
  }

  List<String> _basicTokenize(String text) {
    // Normalization: lowercase and basic cleanup
    final normalized = text.toLowerCase().trim();
    final tokens = <String>[];
    final current = StringBuffer();

    for (int i = 0; i < normalized.length; i++) {
      final char = normalized[i];
      final code = normalized.codeUnitAt(i);

      // Check if punctuation or whitespace
      final isWhitespace = char == ' ' || char == '\t' || char == '\n' || char == '\r';
      final isPunct = (code >= 33 && code <= 47) ||
          (code >= 58 && code <= 64) ||
          (code >= 91 && code <= 96) ||
          (code >= 123 && code <= 126);

      if (isWhitespace) {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current.clear();
        }
      } else if (isPunct) {
        if (current.isNotEmpty) {
          tokens.add(current.toString());
          current.clear();
        }
        tokens.add(char);
      } else {
        current.write(char);
      }
    }

    if (current.isNotEmpty) {
      tokens.add(current.toString());
    }

    return tokens;
  }

  List<int> tokenizeText(String text) {
    final words = _basicTokenize(text);
    final outputTokens = <int>[];

    for (final word in words) {
      if (word.length > 100) {
        outputTokens.add(unkTokenId);
        continue;
      }

      int start = 0;
      bool isBad = false;
      final subTokens = <int>[];

      while (start < word.length) {
        int end = word.length;
        int? curSubTokenId;

        while (start < end) {
          var subStr = word.substring(start, end);
          if (start > 0) {
            subStr = '##$subStr';
          }

          if (vocab.containsKey(subStr)) {
            curSubTokenId = vocab[subStr];
            break;
          }
          end--;
        }

        if (curSubTokenId == null) {
          isBad = true;
          break;
        }

        subTokens.add(curSubTokenId);
        start = end;
      }

      if (isBad) {
        outputTokens.add(unkTokenId);
      } else {
        outputTokens.addAll(subTokens);
      }
    }

    return outputTokens;
  }

  TokenizedPair encodePair(
    String query,
    String text, {
    int maxSeqLength = 256,
  }) {
    final queryTokens = tokenizeText(query);
    var textTokens = tokenizeText(text);

    // Reserved for [CLS], [SEP], [SEP]
    const specialTokensCount = 3;
    final availableForText = maxSeqLength - queryTokens.length - specialTokensCount;

    if (availableForText < 0) {
      // Query itself is very long, truncate query to fit
      final allowedQuery = maxSeqLength - specialTokensCount - 16;
      final truncatedQuery = queryTokens.take(allowedQuery.clamp(1, queryTokens.length)).toList();
      final allowedText = maxSeqLength - truncatedQuery.length - specialTokensCount;
      textTokens = textTokens.take(allowedText.clamp(0, textTokens.length)).toList();
      return _buildPair(truncatedQuery, textTokens, maxSeqLength);
    } else if (textTokens.length > availableForText) {
      textTokens = textTokens.take(availableForText).toList();
    }

    return _buildPair(queryTokens, textTokens, maxSeqLength);
  }

  TokenizedPair _buildPair(
    List<int> queryTokens,
    List<int> textTokens,
    int maxSeqLength,
  ) {
    // [CLS] + query + [SEP] + text + [SEP]
    final inputIds = <int>[
      clsTokenId,
      ...queryTokens,
      sepTokenId,
      ...textTokens,
      sepTokenId,
    ];

    // token_type_ids: 0 for query part, 1 for text part
    final tokenTypeIds = <int>[
      ...List<int>.filled(queryTokens.length + 2, 0, growable: true),
      ...List<int>.filled(textTokens.length + 1, 1, growable: true),
    ];

    // attentionMask must be a growable list so addAll() succeeds when padding
    final attentionMask = <int>[
      ...List<int>.filled(inputIds.length, 1, growable: true),
    ];

    // Pad to maxSeqLength
    final padLength = maxSeqLength - inputIds.length;
    if (padLength > 0) {
      inputIds.addAll(List<int>.filled(padLength, padTokenId));
      tokenTypeIds.addAll(List<int>.filled(padLength, 0));
      attentionMask.addAll(List<int>.filled(padLength, 0));
    }

    return TokenizedPair(
      inputIds: inputIds,
      attentionMask: attentionMask,
      tokenTypeIds: tokenTypeIds,
    );
  }
}

