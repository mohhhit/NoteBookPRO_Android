import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_state.dart';
import '../services/api_service.dart';
import '../services/local_llm_service.dart';
import '../services/online_llm_service.dart';
import '../services/vector_db_service.dart';
import '../utils/web_download.dart';
import '../utils/file_writer.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _geminiKeyController = TextEditingController();
  final _nvidiaKeyController = TextEditingController();
  final _groqKeyController = TextEditingController();
  bool _isTesting = false;
  bool _isSaving = false;
  bool _isLoadingKeys = true;
  String? _geminiKeyStatus;
  String? _nvidiaKeyStatus;
  String? _groqKeyStatus;
  String? _testResult;
  String _selectedOnlineModel = OnlineLlmService.defaultModel;
  bool _isTestingGeminiKey = false;
  String? _geminiTestResult;

  @override
  void initState() {
    super.initState();
    _urlController.text = ApiService.baseUrl;
    _loadApiKeyStatus();
  }

  Future<void> _loadApiKeyStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final localKey = prefs.getString('gemini_api_key');
      final localModel = prefs.getString('gemini_model_name');

      Map<String, String?> config = {};
      try {
        config = await ApiService().getConfig();
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        if (localKey != null && localKey.isNotEmpty) {
          _geminiKeyStatus = localKey.length > 8
              ? '${localKey.substring(0, 4)}...${localKey.substring(localKey.length - 4)}'
              : 'Configured (Local)';
        } else {
          _geminiKeyStatus = config['gemini_api_key'];
        }
        if (localModel != null && localModel.isNotEmpty) {
          _selectedOnlineModel = localModel;
        }
        _nvidiaKeyStatus = config['nvidia_api_key'];
        _groqKeyStatus = config['groq_api_key'];
        _isLoadingKeys = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _isLoadingKeys = false);
      }
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _geminiKeyController.dispose();
    _nvidiaKeyController.dispose();
    _groqKeyController.dispose();
    super.dispose();
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _testResult = null;
    });

    try {
      final testUrl = _urlController.text.trim();

      // Validate URL format
      if (!testUrl.startsWith('http://') && !testUrl.startsWith('https://')) {
        setState(() {
          _testResult = '❌ URL must start with http:// or https://';
          _isTesting = false;
        });
        return;
      }

      print('Testing connection to: $testUrl');

      final healthResponse = await http
          .get(
            Uri.parse('$testUrl/api/health'),
            headers: ApiService.buildHeaders(baseUrl: testUrl),
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw Exception('Connection timeout - backend not responding');
            },
          );

      if (healthResponse.statusCode == 200) {
        setState(() {
          _testResult =
              '✅ Connection successful!\nBackend is responding correctly.';
          _isTesting = false;
        });
      } else if (healthResponse.statusCode == 404) {
        // Backward compatibility for older backend revisions.
        final legacyResponse = await http
            .get(
              Uri.parse('$testUrl/api/spaces'),
              headers: ApiService.buildHeaders(baseUrl: testUrl),
            )
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () {
                throw Exception('Connection timeout - backend not responding');
              },
            );

        if (legacyResponse.statusCode == 200) {
          setState(() {
            _testResult =
                '✅ Connection successful!\nBackend is responding correctly.';
            _isTesting = false;
          });
        } else {
          setState(() {
            _testResult =
                '❌ ${ApiService.formatHttpError(operation: 'Connection test', response: legacyResponse)}';
            _isTesting = false;
          });
        }
      } else {
        setState(() {
          _testResult =
              '❌ ${ApiService.formatHttpError(operation: 'Connection test', response: healthResponse)}';
          _isTesting = false;
        });
      }
    } catch (e) {
      print('Connection error: $e');
      String errorMessage = '❌ Connection failed\n\n';

      if (e.toString().contains('SocketException') ||
          e.toString().contains('NetworkException')) {
        errorMessage +=
            'Cannot reach the server. Check:\n'
            '• Backend is running on your computer\n'
            '• Both devices are on the same WiFi\n'
            '• IP address is correct\n'
            '• Firewall allows port 8000';
      } else if (e.toString().contains('timeout')) {
        errorMessage +=
            'Server is not responding:\n'
            '• Make sure backend is running\n'
            '• Check if server is accessible';
      } else {
        errorMessage += 'Error: ${e.toString()}';
      }

      setState(() {
        _testResult = errorMessage;
        _isTesting = false;
      });
    }
  }

  Future<void> _testGeminiApiKey() async {
    final keyToTest = _geminiKeyController.text.trim().isNotEmpty
        ? _geminiKeyController.text.trim()
        : (context.read<AppState>().geminiApiKey ?? '');

    if (keyToTest.isEmpty) {
      setState(() {
        _geminiTestResult = '⚠️ Please enter an API key to test';
      });
      return;
    }

    setState(() {
      _isTestingGeminiKey = true;
      _geminiTestResult = null;
    });

    final res = await OnlineLlmService.testApiKey(keyToTest, model: _selectedOnlineModel);

    if (!mounted) return;
    setState(() {
      _isTestingGeminiKey = false;
      _geminiTestResult = res['success'] == true
          ? '✅ ${res['message']}'
          : '❌ ${res['message']}';
    });
  }

  Future<void> _saveAndReload() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isSaving = true);
      try {
        final newUrl = _urlController.text.trim();
        await ApiService.setBaseUrl(newUrl);
        final geminiKey = _geminiKeyController.text.trim();
        final nvidiaKey = _nvidiaKeyController.text.trim();
        final groqKey = _groqKeyController.text.trim();

        // 1. Save Gemini settings locally for on-device online execution
        final prefs = await SharedPreferences.getInstance();
        if (geminiKey.isNotEmpty) {
          await prefs.setString('gemini_api_key', geminiKey);
        }
        await prefs.setString('gemini_model_name', _selectedOnlineModel);

        // 2. Also try backend config if available
        try {
          if (geminiKey.isNotEmpty ||
              nvidiaKey.isNotEmpty ||
              groqKey.isNotEmpty) {
            await ApiService().updateConfig(
              geminiKey: geminiKey.isEmpty ? null : geminiKey,
              nvidiaKey: nvidiaKey.isEmpty ? null : nvidiaKey,
              groqKey: groqKey.isEmpty ? null : groqKey,
            );
          }
        } catch (_) {}

        if (mounted) {
          final appState = context.read<AppState>();
          if (geminiKey.isNotEmpty) {
            await appState.setGeminiApiKey(geminiKey);
          }
          await appState.setOnlineModelName(_selectedOnlineModel);
          await appState.initialize();

          Navigator.pop(context);

          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Settings updated successfully!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Could not save settings: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _isSaving = false);
      }
    }
  }

  Widget _buildApiKeyField({
    required String label,
    required String hint,
    required TextEditingController controller,
    required String? status,
    required IconData icon,
  }) {
    final configured = status != null && status!.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: controller,
        obscureText: true,
        enabled: !_isSaving && !_isLoadingKeys,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          hintText: configured
              ? 'Already configured; enter a new key to replace it'
              : hint,
          helperText: configured ? 'Saved key: $status' : 'Not configured',
          helperStyle: TextStyle(
            color: configured ? Colors.green[300] : Colors.grey[500],
          ),
          prefixIcon: Icon(icon),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          filled: true,
          fillColor: const Color(0xFF1E1E1E),
        ),
      ),
    );
  }

  bool _isExporting = false;
  bool _isImporting = false;

  Future<void> _handleExport() async {
    setState(() => _isExporting = true);
    try {
      final bytes = await ApiService().exportData();
      
      if (kIsWeb) {
        downloadPdfBytes(Uint8List.fromList(bytes), 'notebookpro_backup.zip');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Download started')),
          );
        }
      } else {
        String? outputFile = await FilePicker.saveFile(
          dialogTitle: 'Save Backup File',
          fileName: 'notebookpro_backup.zip',
          type: FileType.custom,
          allowedExtensions: ['zip'],
        );

        if (outputFile != null) {
          await saveFileBytes(outputFile, bytes);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Data exported successfully to $outputFile')),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  Future<void> _handleImport() async {
    setState(() => _isImporting = true);
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        dialogTitle: 'Select Backup File',
        type: FileType.custom,
        allowedExtensions: ['zip'],
        withData: kIsWeb,
      );

      if (result != null) {
        if (kIsWeb) {
          final bytes = result.files.single.bytes;
          if (bytes != null) {
            await ApiService().importDataBytes(bytes, result.files.single.name);
          }
        } else {
          if (result.files.single.path != null) {
            await ApiService().importData(result.files.single.path!);
          }
        }
        
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('Import Successful'),
              content: const Text('Data has been imported successfully. Please restart the NotebookPRO backend and application to apply changes.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: const Color(0xFF1E1E1E),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // On-Device AI Status Card
              FutureBuilder<LocalModelInfo>(
                future: LocalLlmService.getModelInfo(),
                builder: (context, snapshot) {
                  final info = snapshot.data;
                  final isReady = info?.modelExists == true;
                  return Container(
                    padding: const EdgeInsets.all(16),
                    margin: const EdgeInsets.only(bottom: 24),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E1E1E),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isReady
                            ? const Color(0xFF38BDF8).withValues(alpha: 0.3)
                            : Colors.orange.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.offline_bolt, color: isReady ? const Color(0xFF38BDF8) : Colors.orange, size: 20),
                            const SizedBox(width: 8),
                            const Text(
                              'On-Device AI Engine & Storage',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Active LLM Model:', style: TextStyle(color: Colors.grey, fontSize: 13)),
                            Text(
                              info?.activeModelName ?? 'Checking...',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('LLM Size on Disk:', style: TextStyle(color: Colors.grey, fontSize: 13)),
                            Text(
                              info != null && info.modelExists
                                  ? '${info.activeModelSizeMb.toStringAsFixed(0)} MB (~${(info.activeModelSizeMb / 1024).toStringAsFixed(2)} GB)'
                                  : (info?.isDownloading == true ? '${info!.partialDownloadMb.toStringAsFixed(0)} MB (Downloading)' : 'Not downloaded'),
                              style: TextStyle(
                                color: isReady ? const Color(0xFF34D399) : Colors.orange,
                                fontWeight: FontWeight.w500,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Neural Reranker:', style: TextStyle(color: Colors.grey, fontSize: 13)),
                            Text(
                              info?.isRerankerReady == true
                                  ? 'ms-marco-MiniLM (${info!.rerankerSizeMb.toStringAsFixed(1)} MB)'
                                  : 'Not loaded',
                              style: TextStyle(
                                color: info?.isRerankerReady == true ? const Color(0xFF34D399) : Colors.grey,
                                fontWeight: FontWeight.w500,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Inference Backend:', style: TextStyle(color: Colors.grey, fontSize: 13)),
                            Text(
                              info?.activeEngine ?? 'LiteRT-LM CPU',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 13),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),

              // Backend Configuration Section
              const Text(
                'Backend Configuration',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Configure the backend server URL to connect to',
                style: TextStyle(fontSize: 14, color: Colors.grey[400]),
              ),
              const SizedBox(height: 24),

              // URL Input Field
              TextFormField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: 'Backend URL',
                  hintText: 'http://192.168.1.100:8000',
                  prefixIcon: const Icon(Icons.link),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  filled: true,
                  fillColor: const Color(0xFF1E1E1E),
                ),
                style: const TextStyle(color: Colors.white),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a backend URL';
                  }
                  if (!value.startsWith('http://') &&
                      !value.startsWith('https://')) {
                    return 'URL must start with http:// or https://';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Help Text
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.blue, size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Connection Guide',
                          style: TextStyle(
                            color: Colors.blue,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _buildHelpItem(
                      '📱 For Android/iOS',
                      'Use your computer\'s local IP address:\nExample: http://192.168.1.100:8000',
                    ),
                    const SizedBox(height: 8),
                    _buildHelpItem(
                      '🌐 For Public Access',
                      'Use ngrok or localtunnel URL:\nExample: https://your-app.ngrok-free.app',
                    ),
                    const SizedBox(height: 8),
                    _buildHelpItem(
                      '💻 For Web/Desktop',
                      'Use localhost:\nExample: http://localhost:8000',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'To find your computer\'s IP:\n'
                      '• Windows: Open CMD and type "ipconfig"\n'
                      '• Mac/Linux: Open Terminal and type "ifconfig"',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Test Connection Button
              if (_isTesting)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  ),
                )
              else
                OutlinedButton.icon(
                  onPressed: _testConnection,
                  icon: const Icon(Icons.wifi_find),
                  label: const Text('Test Connection'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: const BorderSide(color: Colors.blue),
                    foregroundColor: Colors.blue,
                  ),
                ),

              // Test Result
              if (_testResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _testResult!.startsWith('✅')
                          ? Colors.green.withOpacity(0.1)
                          : Colors.red.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: _testResult!.startsWith('✅')
                            ? Colors.green
                            : Colors.red,
                      ),
                    ),
                    child: Text(
                      _testResult!,
                      style: TextStyle(
                        color: _testResult!.startsWith('✅')
                            ? Colors.green
                            : Colors.red,
                      ),
                    ),
                  ),
                ),

              const SizedBox(height: 24),

              const Text(
                'AI Provider API Keys',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Keys are saved by the backend and displayed only in masked form.',
                style: TextStyle(fontSize: 14, color: Colors.grey[400]),
              ),
              const SizedBox(height: 16),
              _buildApiKeyField(
                label: 'Gemini API key (answer generation)',
                hint: 'AIza...',
                controller: _geminiKeyController,
                status: _geminiKeyStatus,
                icon: Icons.auto_awesome,
              ),

              // Online Gemini Model Dropdown & Test Key Button
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedOnlineModel,
                    isExpanded: true,
                    dropdownColor: const Color(0xFF2A2A2A),
                    items: OnlineLlmService.supportedModels.map((m) {
                      return DropdownMenuItem<String>(
                        value: m['id'],
                        child: Text(
                          m['name']!,
                          style: const TextStyle(fontSize: 13, color: Colors.white),
                        ),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedOnlineModel = val);
                      }
                    },
                  ),
                ),
              ),

              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _isTestingGeminiKey ? null : _testGeminiApiKey,
                      icon: _isTestingGeminiKey
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8AB4F8)),
                            )
                          : const Icon(Icons.check_circle_outline, size: 16),
                      label: Text(_isTestingGeminiKey ? 'Verifying...' : 'Verify Gemini Key'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF8AB4F8),
                        side: const BorderSide(color: Color(0xFF8AB4F8)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (_geminiTestResult != null)
                      Expanded(
                        child: Text(
                          _geminiTestResult!,
                          style: TextStyle(
                            fontSize: 12,
                            color: _geminiTestResult!.startsWith('✅') ? Colors.green : Colors.red,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              _buildApiKeyField(
                label: 'NVIDIA NIM API key (follow-ups)',
                hint: 'nvapi-...',
                controller: _nvidiaKeyController,
                status: _nvidiaKeyStatus,
                icon: Icons.memory,
              ),
              _buildApiKeyField(
                label: 'Groq API key (follow-up fallback)',
                hint: 'gsk_...',
                controller: _groqKeyController,
                status: _groqKeyStatus,
                icon: Icons.bolt,
              ),

              const SizedBox(height: 10),

              // Save Button
              ElevatedButton(
                onPressed: _isSaving ? null : _saveAndReload,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8AB4F8),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _isSaving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.black,
                        ),
                      )
                    : const Text(
                        'Save & Reload',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
              const SizedBox(height: 32),

              // Data Management Section
              const Text(
                'Data Management',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Backup and restore your spaces, files, and chats.',
                style: TextStyle(fontSize: 14, color: Colors.grey[400]),
              ),
              const SizedBox(height: 16),
              
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isExporting ? null : _handleExport,
                      icon: _isExporting 
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.download),
                      label: const Text('Export Backup'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: const BorderSide(color: Color(0xFF8AB4F8)),
                        foregroundColor: const Color(0xFF8AB4F8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _isImporting ? null : _handleImport,
                      icon: _isImporting 
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.upload),
                      label: const Text('Import Backup'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: const BorderSide(color: Colors.orangeAccent),
                        foregroundColor: Colors.orangeAccent,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ), // SafeArea
    );
  }

  Widget _buildHelpItem(String title, String description) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: TextStyle(color: Colors.grey[400], fontSize: 12),
        ),
      ],
    );
  }
}
