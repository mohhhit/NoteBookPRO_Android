import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class ModelDownloader {
  // Use /resolve/main/ for the actual binary GGUF download instead of /blob/main/ (which serves HTML)
  static const String _llmUrl =
      'https://huggingface.co/unsloth/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf';

  static Future<void> downloadModelIfMissing(Function(String, double) onProgress) async {
    final docDir = await getApplicationDocumentsDirectory();
    final llmPath = '${docDir.path}/Llama-3.2-3B-Instruct-Q4_K_M.gguf';
    final llmFile = File(llmPath);

    // If a corrupted HTML file or partial file exists from previous attempt, delete it
    if (await llmFile.exists()) {
      final size = await llmFile.length();
      if (size < 500 * 1024 * 1024) {
        // Less than 500MB is corrupted (the real GGUF is ~2.01 GB)
        await llmFile.delete();
      }
    }

    if (!await llmFile.exists()) {
      final dio = Dio(BaseOptions(
        followRedirects: true,
        maxRedirects: 5,
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 60),
      ));

      final tempPath = '$llmPath.part';
      final tempFile = File(tempPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      onProgress('Downloading Llama 3.2 3B Instruct', 0.0);
      await dio.download(
        _llmUrl,
        tempPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress('Downloading Llama 3.2 3B Instruct', received / total);
          }
        },
      );

      // Atomically rename once 100% finished
      await File(tempPath).rename(llmPath);
    }

    onProgress('All Models Loaded', 1.0);
  }
}
