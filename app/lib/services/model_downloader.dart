import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class ModelDownloader {
  // Exact direct binary download link for Gemma 4 E2B LiteRT-LM (~2.58 GB)
  static const String _llmUrl =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm?download=true';
  static const String _rerankerUrl =
      'https://huggingface.co/Xenova/ms-marco-MiniLM-L-6-v2/resolve/main/onnx/model_quantized.onnx';
  static const String _vocabUrl =
      'https://huggingface.co/Xenova/ms-marco-MiniLM-L-6-v2/raw/main/vocab.txt';

  static Future<void> downloadModelIfMissing(Function(String, double) onProgress) async {
    final docDir = await getApplicationDocumentsDirectory();
    final dio = Dio(BaseOptions(
      followRedirects: true,
      maxRedirects: 10,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
    ));

    // 1. Download Vocab if missing (~230 KB)
    final vocabPath = '${docDir.path}/ms-marco-MiniLM-vocab.txt';
    final vocabFile = File(vocabPath);
    if (!await vocabFile.exists() || await vocabFile.length() < 1000) {
      onProgress('Downloading Reranker Vocabulary', 0.0);
      await dio.download(_vocabUrl, vocabPath);
    }

    // 2. Download MiniLM ONNX Reranker (~23 MB) if missing
    final rerankerPath = '${docDir.path}/ms-marco-MiniLM-L-6-v2-quantized.onnx';
    final rerankerFile = File(rerankerPath);
    if (await rerankerFile.exists() && await rerankerFile.length() < 10 * 1024 * 1024) {
      await rerankerFile.delete();
    }
    if (!await rerankerFile.exists()) {
      await _downloadResumable(
        dio,
        _rerankerUrl,
        rerankerPath,
        'Downloading MiniLM Reranker Model',
        onProgress,
      );
    }

    // 3. Free bulky previous models (Gemma 4 E4B ~3.66 GB, LLaMA ~2.01 GB) to reclaim device storage
    final legacyModels = [
      File('${docDir.path}/gemma-4-E4B-it.litertlm'),
      File('${docDir.path}/gemma-4-E4B-it.litertlm.part'),
      File('${docDir.path}/Llama-3.2-3B-Instruct-Q4_K_M.gguf'),
    ];
    for (final legacy in legacyModels) {
      if (await legacy.exists()) {
        try {
          await legacy.delete();
        } catch (_) {}
      }
    }

    // 4. Download Gemma 4 E2B LiteRT-LM (~2.58 GB) with HTTP Range resume support
    final llmPath = '${docDir.path}/gemma-4-E2B-it.litertlm';
    final llmFile = File(llmPath);

    // If an incomplete or corrupted final file exists (< 800 MB), delete it
    if (await llmFile.exists()) {
      final size = await llmFile.length();
      if (size < 800 * 1024 * 1024) {
        await llmFile.delete();
      }
    }

    if (!await llmFile.exists()) {
      await _downloadResumable(
        dio,
        _llmUrl,
        llmPath,
        'Downloading Gemma 4 E2B LiteRT-LM',
        onProgress,
        maxRetries: 30,
      );
    }

    onProgress('All Models Loaded', 1.0);
  }

  /// Downloads a file with HTTP Range resume support and exponential auto-retry.
  /// Survives app backgrounding, transient socket dropouts, and Bluetooth/Wi-Fi toggles.
  static Future<void> _downloadResumable(
    Dio dio,
    String url,
    String destinationPath,
    String label,
    Function(String, double) onProgress, {
    int maxRetries = 20,
  }) async {
    final tempPath = '$destinationPath.part';
    final tempFile = File(tempPath);

    int totalBytes = 0;
    int retryCount = 0;

    while (retryCount < maxRetries) {
      int downloadedBytes = 0;
      if (await tempFile.exists()) {
        downloadedBytes = await tempFile.length();
      }

      try {
        final headers = <String, dynamic>{};
        if (downloadedBytes > 0) {
          headers['Range'] = 'bytes=$downloadedBytes-';
        }

        final options = Options(
          responseType: ResponseType.stream,
          followRedirects: true,
          maxRedirects: 10,
          headers: headers.isNotEmpty ? headers : null,
          validateStatus: (status) =>
              status != null && (status == 200 || status == 206),
        );

        final response = await dio.get<ResponseBody>(url, options: options);
        final statusCode = response.statusCode ?? 200;

        if (statusCode == 206) {
          // Range accepted: parse total size from Content-Range (bytes start-end/total)
          final contentRange = response.headers.value('content-range');
          if (contentRange != null && contentRange.contains('/')) {
            final totalStr = contentRange.split('/').last.trim();
            totalBytes = int.tryParse(totalStr) ?? totalBytes;
          }
        } else {
          // Server returned 200 OK: restart from byte 0
          downloadedBytes = 0;
          final cl = response.headers.value('content-length');
          if (cl != null) {
            totalBytes = int.tryParse(cl) ?? totalBytes;
          }
        }

        final openMode = (statusCode == 206 && downloadedBytes > 0)
            ? FileMode.append
            : FileMode.write;
        final sink = tempFile.openWrite(mode: openMode);

        try {
          await for (final chunk in response.data!.stream) {
            sink.add(chunk);
            downloadedBytes += chunk.length;

            if (totalBytes > 0) {
              final progress = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
              onProgress(label, progress);
            }
          }

          await sink.flush();
          await sink.close();

          // Verify file length before renaming
          final finishedLength = await tempFile.length();
          if (totalBytes > 0 && finishedLength < totalBytes) {
            throw Exception('Incomplete stream: received $finishedLength of $totalBytes bytes');
          }

          // Atomically rename .part to final target
          await tempFile.rename(destinationPath);
          return;
        } catch (streamError) {
          try {
            await sink.flush();
            await sink.close();
          } catch (_) {}
          rethrow;
        }
      } catch (e) {
        retryCount++;
        if (retryCount >= maxRetries) {
          throw Exception('$label failed after $maxRetries reconnect attempts: $e');
        }

        final retryProgress = totalBytes > 0
            ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
            : 0.0;
        onProgress('$label (Reconnecting...)', retryProgress);

        final backoff = Duration(seconds: retryCount <= 3 ? 2 : 5);
        await Future.delayed(backoff);
      }
    }
  }
}
