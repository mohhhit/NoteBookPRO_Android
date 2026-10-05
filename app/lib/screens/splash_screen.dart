import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/model_downloader.dart';
import '../services/local_llm_service.dart';
import '../services/local_database_service.dart';
import '../services/vector_db_service.dart';
import '../main.dart'; // To navigate to HomePage

class SplashScreen extends StatefulWidget {
  @override
  _SplashScreenState createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  double _progress = 0.0;
  String _status = 'Initializing...';
  bool _isDownloading = false;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _checkAndDownloadModel();
  }

  Future<void> _checkAndDownloadModel() async {
    try {
      setState(() {
        _hasError = false;
        _status = 'Checking AI model...';
      });

      // Keep screen awake during massive 1GB download so OS doesn't kill network
      await WakelockPlus.enable();

      await ModelDownloader.downloadModelIfMissing((label, progress) {
        setState(() {
          _isDownloading = true;
          _progress = progress;
          _status = '$label...\n${(progress * 100).toStringAsFixed(1)}%';
        });
      });

      setState(() {
        _isDownloading = false;
        _status = 'Loading AI into Memory...';
      });

      // Initialize Native Database
      await LocalDatabaseService.initialize();

      // Initialize the Native C++ LLM
      await LocalLlmService.initialize();
      
      // Initialize Vector DB
      await VectorDbService.initialize();

      await WakelockPlus.disable();

      // Navigate to Home
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => HomePage()),
        );
      }
    } catch (e) {
      await WakelockPlus.disable();
      setState(() {
        _hasError = true;
        _status = 'Error initializing AI:\n$e';
        _isDownloading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E1E),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.auto_awesome, size: 64, color: Color(0xFF8AB4F8)),
              const SizedBox(height: 24),
              const Text(
                'NotebookPRO Local',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 32),
              if (_hasError)
                ElevatedButton.icon(
                  onPressed: _checkAndDownloadModel,
                  icon: const Icon(Icons.refresh),
                  label: const Text("Retry Download"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8AB4F8),
                    foregroundColor: const Color(0xFF1E1E1E),
                  ),
                )
              else if (_isDownloading)
                LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: const Color(0xFF2D2D2D),
                  valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF8AB4F8)),
                )
              else
                const CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8AB4F8)),
                ),
              const SizedBox(height: 24),
              Text(
                _status,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: _hasError ? Colors.redAccent : const Color(0xFF9AA0A6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

