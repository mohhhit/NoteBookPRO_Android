import 'package:flutter/material.dart';
import '../services/api_service.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = true;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _loadCurrentUrl();
  }

  Future<void> _loadCurrentUrl() async {
    final url = await ApiService.getBaseUrl();
    setState(() {
      _urlController.text = url;
      _isLoading = false;
    });
  }

  Future<void> _saveUrl() async {
    setState(() {
      _error = null;
      _success = null;
      _isLoading = true;
    });

    try {
      String url = _urlController.text.trim();
      
      // Validate URL
      if (url.isEmpty) {
        throw Exception('URL cannot be empty');
      }
      
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        throw Exception('URL must start with http:// or https://');
      }
      
      // Remove trailing slash
      if (url.endsWith('/')) {
        url = url.substring(0, url.length - 1);
      }
      
      await ApiService.setBaseUrl(url);
      
      setState(() {
        _success = 'Backend URL saved successfully!';
        _isLoading = false;
      });
      
      // Close dialog after 1 second
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) {
        Navigator.of(context).pop(true); // Return true to indicate URL was changed
      }
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      title: const Row(
        children: [
          Icon(Icons.settings, color: Color(0xFF8AB4F8), size: 24),
          SizedBox(width: 8),
          Text(
            'Backend Settings',
            style: TextStyle(color: Colors.white, fontSize: 20),
          ),
        ],
      ),
      content: Container(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Configure your backend server URL:',
              style: TextStyle(color: Color(0xFFB0B0B0), fontSize: 14),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              enabled: !_isLoading,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Backend URL',
                labelStyle: const TextStyle(color: Color(0xFF8AB4F8)),
                hintText: 'http://your-pc-ip:8000 or https://your-ngrok-url.app',
                hintStyle: const TextStyle(color: Color(0xFF505050)),
                filled: true,
                fillColor: const Color(0xFF2D2D2D),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                prefixIcon: const Icon(Icons.link, color: Color(0xFF8AB4F8)),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF2D2D2D),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.info_outline, color: Color(0xFF8AB4F8), size: 16),
                      SizedBox(width: 6),
                      Text(
                        'Examples:',
                        style: TextStyle(
                          color: Color(0xFF8AB4F8),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildExample('Local PC', 'http://192.168.1.100:8000'),
                  _buildExample('Ngrok Tunnel', 'https://abc123.ngrok-free.app'),
                  _buildExample('LocalTunnel', 'https://yoursubdomain.loca.lt'),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_success != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.green.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.green.withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_outline, color: Colors.green, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _success!,
                          style: const TextStyle(color: Colors.green, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Color(0xFF8AB4F8))),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _saveUrl,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF8AB4F8),
            foregroundColor: Colors.black,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                )
              : const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildExample(String label, String url) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: const TextStyle(color: Color(0xFF808080), fontSize: 11),
          ),
          Expanded(
            child: Text(
              url,
              style: const TextStyle(color: Color(0xFFB0B0B0), fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }
}
