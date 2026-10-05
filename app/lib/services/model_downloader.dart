import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class ModelDownloader {
  static const String _llmUrl = 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf';
  static const String _embedUrl = 'https://huggingface.co/second-state/All-MiniLM-L6-v2-Embedding-GGUF/resolve/main/all-MiniLM-L6-v2-ggml-model-f16.gguf';
  
  static Future<void> downloadModelIfMissing(Function(String, double) onProgress) async {
    final docDir = await getApplicationDocumentsDirectory();
    final llmPath = '${docDir.path}/qwen2.5-1.5b-instruct-q4_k_m.gguf';
    final embedPath = '${docDir.path}/all-MiniLM-L6-v2-ggml-model-f16.gguf';
    
    final llmFile = File(llmPath);
    final embedFile = File(embedPath);

    final dio = Dio();

    if (!await llmFile.exists()) {
      onProgress('Downloading Qwen2.5 1.5B (1/2)', 0.0);
      await dio.download(
        _llmUrl,
        llmPath,
        onReceiveProgress: (received, total) {
          if (total != -1) onProgress('Downloading Qwen2.5 1.5B (1/2)', received / total);
        },
      );
    }

    if (!await embedFile.exists()) {
      onProgress('Downloading MiniLM Embedder (2/2)', 0.0);
      await dio.download(
        _embedUrl,
        embedPath,
        onReceiveProgress: (received, total) {
          if (total != -1) onProgress('Downloading MiniLM Embedder (2/2)', received / total);
        },
      );
    }

    onProgress('All Models Loaded', 1.0);
  }
}
