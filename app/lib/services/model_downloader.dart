import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class ModelDownloader {
  static const String _llmUrl = 'https://huggingface.co/unsloth/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true';
  
  static Future<void> downloadModelIfMissing(Function(String, double) onProgress) async {
    final docDir = await getApplicationDocumentsDirectory();
    final llmPath = '${docDir.path}/Llama-3.2-3B-Instruct-Q4_K_M.gguf';
    
    final llmFile = File(llmPath);

    final dio = Dio();

    if (!await llmFile.exists()) {
      onProgress('Downloading Llama-3.2 3B (1/1)', 0.0);
      await dio.download(
        _llmUrl,
        llmPath,
        onReceiveProgress: (received, total) {
          if (total != -1) onProgress('Downloading Llama-3.2 3B (1/1)', received / total);
        },
      );
    }

    onProgress('All Models Loaded', 1.0);
  }
}
