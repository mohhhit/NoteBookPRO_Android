import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class ModelDownloader {
  static const String _llmUrl = 'https://huggingface.co/unsloth/gemma-4-E4B-it-qat-GGUF/resolve/main/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf?download=true';
  
  static Future<void> downloadModelIfMissing(Function(String, double) onProgress) async {
    final docDir = await getApplicationDocumentsDirectory();
    final llmPath = '${docDir.path}/gemma-4-E4B-it-qat-UD-Q4_K_XL.gguf';
    
    final llmFile = File(llmPath);

    final dio = Dio();

    if (!await llmFile.exists()) {
      onProgress('Downloading Gemma 4 E4B (1/1)', 0.0);
      await dio.download(
        _llmUrl,
        llmPath,
        onReceiveProgress: (received, total) {
          if (total != -1) onProgress('Downloading Gemma 4 E4B (1/1)', received / total);
        },
      );
    }

    onProgress('All Models Loaded', 1.0);
  }
}
