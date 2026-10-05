import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_quill/flutter_quill.dart' as quill;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import '../models/studio_models.dart';
import '../services/studio_service.dart';
import '../utils/web_download.dart';
import 'dart:convert';
import 'dart:typed_data';

Future<bool> _savePdfToDevice({
  required String dialogTitle,
  required String fileName,
  required Uint8List bytes,
}) async {
  if (kIsWeb) {
    await downloadPdfBytes(bytes, fileName);
    return true;
  }

  if (Platform.isAndroid || Platform.isIOS) {
    final mobilePath = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      bytes: bytes,
    );
    return mobilePath != null && mobilePath.isNotEmpty;
  }

  final savePath = await FilePicker.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: const ['pdf'],
  );

  if (savePath == null || savePath.isEmpty) return false;
  await File(savePath).writeAsBytes(bytes, flush: true);
  return true;
}

class _InlineMathSyntaxStudio extends md.InlineSyntax {
  _InlineMathSyntaxStudio() : super(r'\$([^$\n]+?)\$', startCharacter: 36);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final formula = (match[1] ?? '').trim();
    if (formula.isEmpty) {
      return false;
    }
    parser.addNode(md.Element.text('math-inline', formula));
    return true;
  }
}

class _BlockMathSyntaxStudio extends md.InlineSyntax {
  _BlockMathSyntaxStudio() : super(r'\$\$([\s\S]+?)\$\$', startCharacter: 36);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final formula = (match[1] ?? '').trim();
    if (formula.isEmpty) {
      return false;
    }
    parser.addNode(md.Element.text('math-block', formula));
    return true;
  }
}

class _MathElementBuilderStudio extends MarkdownElementBuilder {
  _MathElementBuilderStudio({required this.isBlock});

  final bool isBlock;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final expression = element.textContent.trim();
    if (expression.isEmpty) {
      return const SizedBox.shrink();
    }

    final baseStyle =
        preferredStyle ?? const TextStyle(color: Color(0xFFE8EAED), fontSize: 16);
    final inlineFont = (((baseStyle.fontSize ?? 16) - 1).clamp(12, 16)).toDouble();
    final effectiveStyle = isBlock
        ? baseStyle.copyWith(color: const Color(0xFFE8EAED), height: 1.45)
        : baseStyle.copyWith(
            color: const Color(0xFFE8EAED),
            fontSize: inlineFont,
            height: (baseStyle.height ?? 1.4) + 0.2,
          );

    final math = Math.tex(
      expression,
      mathStyle: isBlock ? MathStyle.display : MathStyle.text,
      textStyle: effectiveStyle,
      onErrorFallback: (FlutterMathException e) => Text(
        expression,
        style: effectiveStyle,
      ),
    );

    if (isBlock) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: math,
        ),
      );
    }

    return math;
  }
}

String _latexExpressionToPlainText(String expr) {
  var out = expr;
  const replacements = {
    r'\log': 'log',
    r'\ln': 'ln',
    r'\mu': 'mu',
    r'\sigma': 'sigma',
    r'\alpha': 'alpha',
    r'\beta': 'beta',
    r'\gamma': 'gamma',
    r'\delta': 'delta',
    r'\theta': 'theta',
    r'\lambda': 'lambda',
    r'\pi': 'pi',
    r'\times': 'x',
    r'\cdot': '*',
  };

  replacements.forEach((key, value) {
    out = out.replaceAll(key, value);
  });

  out = out.replaceAll('{', '').replaceAll('}', '');
  out = out.replaceAll(r'\(', '(').replaceAll(r'\)', ')');
  out = out.replaceAll(r'\[', '[').replaceAll(r'\]', ']');
  out = out.replaceAll(r'\%', '%');
  out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
  return out;
}

String _normalizeMathTextForDisplay(String input) {
  var text = input;
  text = text.replaceAll(r'\$', r'$');
  text = text.replaceAll('\\\\', '\\');

  text = text.replaceAllMapped(
    RegExp(r'\$\$([\s\S]+?)\$\$'),
    (m) => _latexExpressionToPlainText((m.group(1) ?? '').trim()),
  );

  text = text.replaceAllMapped(
    RegExp(r'\$([^$\n]+?)\$'),
    (m) => _latexExpressionToPlainText((m.group(1) ?? '').trim()),
  );

  return text;
}

String _normalizeMathMarkupForRender(String input) {
  var text = input;
  text = text.replaceAll('\\\\', '\\');
  text = text.replaceAll(r'\$', r'$');
  text = text.replaceAllMapped(
    RegExp(r'\\\[([\s\S]*?)\\\]'),
    (m) => '\n\$\$${(m.group(1) ?? '').trim()}\$\$\n',
  );
  text = text.replaceAllMapped(
    RegExp(r'\\\(([^\n]*?)\\\)'),
    (m) => '\n\$${(m.group(1) ?? '').trim()}\$\n',
  );
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text;
}

String _convertMathInsideTableRowsForRender(String input) {
  final lines = input.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final out = <String>[];

  for (final line in lines) {
    final trimmed = line.trim();
    final isTableLike = trimmed.startsWith('|') && trimmed.endsWith('|') && trimmed.split('|').length >= 3;
    if (!isTableLike) {
      out.add(line);
      continue;
    }
    
    var converted = line;
    converted = converted.replaceAllMapped(
      RegExp(r'\$\$([\s\S]+?)\$\$'),
      (m) => _latexExpressionToPlainText((m.group(1) ?? '').trim()),
    );
    converted = converted.replaceAllMapped(
      RegExp(r'\$([^$\n]+?)\$'),
      (m) => _latexExpressionToPlainText((m.group(1) ?? '').trim()),
    );
    out.add(converted);
  }

  return out.join('\n');
}

class StudioScreen extends StatefulWidget {
  final String spaceId;
  final String spaceName;

  const StudioScreen({Key? key, required this.spaceId, required this.spaceName})
    : super(key: key);

  @override
  State<StudioScreen> createState() => _StudioScreenState();
}

class _StudioScreenState extends State<StudioScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Studio', style: TextStyle(fontSize: 20)),
            Text(
              widget.spaceName,
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1E1E1E),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: const Color(0xFF8AB4F8),
          labelColor: const Color(0xFF8AB4F8),
          unselectedLabelColor: Colors.grey[400],
          tabs: const [
            Tab(icon: Icon(Icons.book), text: 'Notebook'),
            Tab(icon: Icon(Icons.style), text: 'Flashcards'),
            Tab(icon: Icon(Icons.quiz), text: 'Quiz'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          NotebookTab(spaceId: widget.spaceId),
          FlashcardsTab(spaceId: widget.spaceId),
          QuizTab(spaceId: widget.spaceId),
        ],
      ),
    );
  }
}

// ============================================================================
// NOTEBOOK TAB
// ============================================================================

class NotebookTab extends StatefulWidget {
  final String spaceId;

  const NotebookTab({Key? key, required this.spaceId}) : super(key: key);

  @override
  State<NotebookTab> createState() => _NotebookTabState();
}

class _NotebookTabState extends State<NotebookTab> {
  List<NotebookEntry> _entries = [];
  bool _loading = true;
  String? _error;
  final List<String> _selectedEntryIds = <String>[];

  bool get _isSelectionMode => _selectedEntryIds.isNotEmpty;
  bool get _areAllEntriesSelected =>
      _entries.isNotEmpty && _selectedEntryIds.length == _entries.length;

  String _normalizeCompareText(String value) {
    var v = value.toLowerCase().trim();
    v = v.replaceAll('...', ' ');
    v = v.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    v = v.replaceAll(RegExp(r'\s+'), ' ').trim();
    return v;
  }

  bool _isSameQuestionTitle(String title, String question) {
    final t = _normalizeCompareText(title);
    final q = _normalizeCompareText(question);
    if (t.isEmpty || q.isEmpty) return false;
    if (t == q) return true;
    if (t.length >= 18 && q.startsWith(t)) return true;
    if (q.length >= 18 && t.startsWith(q)) return true;

    final tTokens = t.split(' ');
    final qTokens = q.split(' ');
    final common = [
      tTokens.length,
      qTokens.length,
      8,
    ].reduce((a, b) => a < b ? a : b);
    if (common >= 4) {
      for (int i = 0; i < common; i++) {
        if (tTokens[i] != qTokens[i]) return false;
      }
      return true;
    }
    return false;
  }

  String _extractPlainText(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return '';

    try {
      final decoded = jsonDecode(trimmed);
      final ops = decoded is List
          ? decoded
          : (decoded is Map<String, dynamic> ? decoded['ops'] : null);

      if (ops is List) {
        final buf = StringBuffer();
        for (final op in ops) {
          if (op is Map && op['insert'] is String) {
            buf.write(op['insert'] as String);
          }
        }
        return buf.toString().trim();
      }
    } catch (_) {
      // Not JSON delta, treat as plain text.
    }

    return trimmed;
  }

  String _withoutDuplicateChatQuestion(NotebookEntry entry, String text) {
    if (entry.sourceType != 'chat') return text;

    final match = RegExp(
      r'^\s*Q:\s*(.*?)\s*\n\s*\n\s*A:\s*(.*)$',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return text;

    final q = (match.group(1) ?? '').trim();
    final a = (match.group(2) ?? '').trim();
    final t = entry.title.trim();

    if (q.isEmpty || a.isEmpty) return text;
    if (_isSameQuestionTitle(t, q)) return a;
    return 'Q: ${match.group(1)!.trim()}\n\nA: $a';
  }

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final entries = await StudioService.listNotebookEntries(
        spaceId: widget.spaceId,
      );
      setState(() {
        _entries = entries;
        _selectedEntryIds.removeWhere(
          (id) => !_entries.any((entry) => entry.id == id),
        );
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _createEntry() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _NotebookEntryDialog(),
    );

    if (result != null) {
      try {
        await StudioService.createNotebookEntry(
          spaceId: widget.spaceId,
          title: result['title']!,
          content: result['content']!,
        );
        _loadEntries();
      } catch (e) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _deleteEntry(String entryId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Entry'),
        content: const Text('Are you sure you want to delete this note?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await StudioService.deleteNotebookEntry(entryId);
        _loadEntries();
      } catch (e) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _downloadEntryPdf(NotebookEntry entry) async {
    try {
      final result = await StudioService.exportNotebookEntryPdf(
        entryId: entry.id,
      );
      final saved = await _savePdfToDevice(
        dialogTitle: 'Save notebook entry PDF',
        fileName: result.filename,
        bytes: result.bytes,
      );
      if (!saved) return;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Notebook entry PDF saved'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error exporting entry PDF: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _downloadSelectedEntriesPdf() async {
    if (_selectedEntryIds.isEmpty) return;

    try {
      final orderedIds = _selectedEntryIds
          .where((id) => _entries.any((entry) => entry.id == id))
          .toList();

      final result = await StudioService.exportSelectedNotebookEntriesPdf(
        spaceId: widget.spaceId,
        entryIds: orderedIds,
        title: 'Notebook Selection',
      );

      final saved = await _savePdfToDevice(
        dialogTitle: 'Save selected notebook PDF',
        fileName: result.filename,
        bytes: result.bytes,
      );
      if (!saved) return;

      if (!mounted) return;
      setState(() {
        _selectedEntryIds.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selected notebook PDF saved'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error exporting selected PDF: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteSelectedEntries() async {
    if (_selectedEntryIds.isEmpty) return;

    final selectedCount = _selectedEntryIds.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Selected Notes'),
        content: Text(
          'Delete $selectedCount selected ${selectedCount == 1 ? 'note' : 'notes'}? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final selectedIds = _selectedEntryIds.toList();
      for (final entryId in selectedIds) {
        await StudioService.deleteNotebookEntry(entryId);
      }

      if (!mounted) return;
      setState(() {
        _selectedEntryIds.clear();
      });

      await _loadEntries();
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Deleted $selectedCount ${selectedCount == 1 ? 'note' : 'notes'}',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error deleting selected notes: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  void _toggleEntrySelection(String entryId) {
    setState(() {
      if (_selectedEntryIds.contains(entryId)) {
        _selectedEntryIds.remove(entryId);
      } else {
        _selectedEntryIds.add(entryId);
      }
    });
  }

  void _enterSelectionMode(String entryId) {
    setState(() {
      _selectedEntryIds.add(entryId);
    });
  }

  void _toggleSelectAll(bool? value) {
    setState(() {
      if (value == true) {
        _selectedEntryIds
          ..clear()
          ..addAll(_entries.map((entry) => entry.id));
      } else {
        _selectedEntryIds.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Error: $_error', style: const TextStyle(color: Colors.red)),
            ElevatedButton(onPressed: _loadEntries, child: const Text('Retry')),
          ],
        ),
      );
    }

    final isCompactLayout = MediaQuery.of(context).size.width < 700;
    final listBottomPadding = _isSelectionMode
      ? (isCompactLayout ? 128.0 : 100.0)
      : (isCompactLayout ? 148.0 : 112.0);

    return Stack(
      children: [
        if (_entries.isEmpty)
          const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.book_outlined, size: 64, color: Colors.grey),
                SizedBox(height: 16),
                Text(
                  'No notebook entries yet',
                  style: TextStyle(color: Colors.grey, fontSize: 16),
                ),
                SizedBox(height: 8),
                Text(
                  'Tap + to create your first note',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          )
        else
          RefreshIndicator(
            onRefresh: _loadEntries,
            child: ListView.builder(
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                listBottomPadding,
              ),
              itemCount: _entries.length,
              itemBuilder: (context, index) {
                final entry = _entries[index];
                final selectionOrder = _selectedEntryIds.indexOf(entry.id);
                final previewText = _withoutDuplicateChatQuestion(
                  entry,
                  _normalizeMathTextForDisplay(
                    _extractPlainText(entry.content),
                  ),
                );
                return Card(
                  color: const Color(0xFF1E1E1E),
                  margin: const EdgeInsets.only(bottom: 12),
                  child: ListTile(
                    titleAlignment: ListTileTitleAlignment.top,
                    contentPadding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
                    horizontalTitleGap: 20,
                    minLeadingWidth: 26,
                    leading: _isSelectionMode
                        ? SizedBox(
                            width: 30,
                            height: 56,
                            child: Stack(
                              children: [
                                Align(
                                  alignment: Alignment.topCenter,
                                  child: Checkbox(
                                    value: _selectedEntryIds.contains(entry.id),
                                    onChanged: (_) => _toggleEntrySelection(entry.id),
                                    activeColor: const Color(0xFF8AB4F8),
                                    checkColor: Colors.black,
                                    side: const BorderSide(color: Colors.white54),
                                    materialTapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                                if (selectionOrder >= 0)
                                  Align(
                                    alignment: Alignment.bottomCenter,
                                    child: Text(
                                      '${selectionOrder + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          )
                        : null,
                    title: Text(
                      entry.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        Text(
                          previewText.length > 100
                              ? '${previewText.substring(0, 100)}...'
                              : previewText,
                          style: TextStyle(color: Colors.grey[400]),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Updated: ${_formatDate(entry.updatedAt)}',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    trailing: _isSelectionMode
                        ? null
                        : PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert, color: Colors.white70),
                            onSelected: (value) {
                              if (value == 'download_pdf') {
                                _downloadEntryPdf(entry);
                              } else if (value == 'delete') {
                                _deleteEntry(entry.id);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem<String>(
                                value: 'download_pdf',
                                child: Row(
                                  children: [
                                    Icon(Icons.picture_as_pdf_outlined, size: 18),
                                    SizedBox(width: 8),
                                    Text('Download as PDF'),
                                  ],
                                ),
                              ),
                              PopupMenuItem<String>(
                                value: 'delete',
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                      color: Colors.red,
                                    ),
                                    SizedBox(width: 8),
                                    Text('Delete'),
                                  ],
                                ),
                              ),
                            ],
                          ),
                    onTap: () {
                      if (_isSelectionMode) {
                        _toggleEntrySelection(entry.id);
                        return;
                      }

                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => NotebookEntryDetailScreen(
                            entry: entry,
                            onUpdate: _loadEntries,
                          ),
                        ),
                      );
                    },
                    onLongPress: () {
                      if (_isSelectionMode) {
                        _toggleEntrySelection(entry.id);
                      } else {
                        _enterSelectionMode(entry.id);
                      }
                    },
                  ),
                );
              },
            ),
          ),
        if (_isSelectionMode)
          Positioned(
            left: 16,
            right: 16,
            bottom: 8,
            child: SafeArea(
              top: false,
              child: Material(
                color: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _toggleSelectAll(!_areAllEntriesSelected),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Checkbox(
                                value: _areAllEntriesSelected,
                                onChanged: _toggleSelectAll,
                                activeColor: const Color(0xFF8AB4F8),
                                checkColor: Colors.black,
                                side: const BorderSide(color: Colors.white54),
                              ),
                              const Text('Select All'),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: _selectedEntryIds.isEmpty
                                      ? null
                                      : _deleteSelectedEntries,
                                  tooltip: 'Delete Selected',
                                  iconSize: 34,
                                  style: IconButton.styleFrom(
                                    backgroundColor: Colors.transparent,
                                    foregroundColor: const Color(0xFF9AA0A6),
                                    disabledForegroundColor: Colors.white24,
                                    minimumSize: const Size(42, 42),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  icon: const Icon(Icons.delete_forever_rounded),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  onPressed: _selectedEntryIds.isEmpty
                                      ? null
                                      : _downloadSelectedEntriesPdf,
                                  tooltip:
                                      'Download Selected (${_selectedEntryIds.length})',
                                  iconSize: 32,
                                  style: IconButton.styleFrom(
                                    backgroundColor: Colors.transparent,
                                    foregroundColor: const Color(0xFF8AB4F8),
                                    disabledForegroundColor: Colors.white24,
                                    minimumSize: const Size(42, 42),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                  ),
                                  icon: const Icon(Icons.picture_as_pdf_rounded),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (!_isSelectionMode)
          Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton(
            onPressed: _createEntry,
            backgroundColor: const Color(0xFF8AB4F8),
            child: const Icon(Icons.add, color: Colors.black),
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0) {
      if (diff.inHours == 0) {
        return '${diff.inMinutes}m ago';
      }
      return '${diff.inHours}h ago';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}d ago';
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }
}

// Notebook Entry Dialog
class _NotebookEntryDialog extends StatefulWidget {
  @override
  State<_NotebookEntryDialog> createState() => _NotebookEntryDialogState();
}

class _NotebookEntryDialogState extends State<_NotebookEntryDialog> {
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New Note'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _contentController,
              decoration: const InputDecoration(
                labelText: 'Content',
                border: OutlineInputBorder(),
              ),
              maxLines: 5,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_titleController.text.isNotEmpty &&
                _contentController.text.isNotEmpty) {
              Navigator.pop(context, {
                'title': _titleController.text,
                'content': _contentController.text,
              });
            }
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}

// ============================================================================
// NOTEBOOK ENTRY DETAIL SCREEN - GOOGLE DOCS STYLE RICH TEXT EDITOR
// ============================================================================

class NotebookEntryDetailScreen extends StatefulWidget {
  final NotebookEntry entry;
  final VoidCallback onUpdate;

  const NotebookEntryDetailScreen({
    Key? key,
    required this.entry,
    required this.onUpdate,
  }) : super(key: key);

  @override
  State<NotebookEntryDetailScreen> createState() =>
      _NotebookEntryDetailScreenState();
}

class _MarkdownTableBlock {
  final int startLine;
  final int endLine;
  final List<List<String>> rows;

  const _MarkdownTableBlock({
    required this.startLine,
    required this.endLine,
    required this.rows,
  });
}

class _NotebookEntryDetailScreenState extends State<NotebookEntryDetailScreen> {
  late quill.QuillController _controller;
  final FocusNode _editorFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  bool _isSaving = false;
  bool _previewMode = false;

  void _onEditorChanged() {
    if (!_previewMode && mounted) {
      setState(() {});
    }
  }

  String _normalizeCompareText(String value) {
    var v = value.toLowerCase().trim();
    v = v.replaceAll('...', ' ');
    v = v.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    v = v.replaceAll(RegExp(r'\s+'), ' ').trim();
    return v;
  }

  bool _isSameQuestionTitle(String title, String question) {
    final t = _normalizeCompareText(title);
    final q = _normalizeCompareText(question);
    if (t.isEmpty || q.isEmpty) return false;
    if (t == q) return true;
    if (t.length >= 18 && q.startsWith(t)) return true;
    if (q.length >= 18 && t.startsWith(q)) return true;

    final tTokens = t.split(' ');
    final qTokens = q.split(' ');
    final common = [
      tTokens.length,
      qTokens.length,
      8,
    ].reduce((a, b) => a < b ? a : b);
    if (common >= 4) {
      for (int i = 0; i < common; i++) {
        if (tTokens[i] != qTokens[i]) return false;
      }
      return true;
    }
    return false;
  }

  String _stripDuplicateChatQuestion(String raw) {
    if (widget.entry.sourceType != 'chat') return raw;

    final text = raw.trim();
    final match = RegExp(
      r'^\s*Q:\s*(.*?)\s*\n\s*\n\s*A:\s*(.*)$',
      dotAll: true,
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return raw;

    final q = (match.group(1) ?? '').trim();
    final a = (match.group(2) ?? '').trim();
    final t = widget.entry.title.trim();

    if (q.isEmpty || a.isEmpty) return raw;
    if (_isSameQuestionTitle(t, q)) return a;
    return raw;
  }

  bool _looksLikeMarkdown(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return false;
    return RegExp(
      r'(^#{1,6}\s+)|(^\s*[-*]\s+)|(^\s*\d+\.\s+)|(\*\*[^*]+\*\*)|(\|.+\|)',
      multiLine: true,
    ).hasMatch(trimmed);
  }

  String _stripInlineMarkdown(String text) {
    var out = text;
    out = out.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\(([^\)]+)\)'),
      (m) => m.group(1) ?? '',
    );
    out = out.replaceAllMapped(
      RegExp(r'\*\*([^*\n]+)\*\*'),
      (m) => m.group(1) ?? '',
    );
    out = out.replaceAllMapped(
      RegExp(r'__([^_\n]+)__'),
      (m) => m.group(1) ?? '',
    );
    out = out.replaceAllMapped(
      RegExp(r'\*([^*\n]+)\*'),
      (m) => m.group(1) ?? '',
    );
    out = out.replaceAll('`', '');
    out = out.replaceAll(RegExp(r'(?<=\s)\*(?=\S)|(?<=\S)\*(?=\s|$)'), '');
    out = out.replaceAll(r'\$', r'$');
    out = out.replaceAll('\\\\', '\\');
    return out;
  }

  bool _isMarkdownTableSeparator(String line) {
    if (!line.contains('|')) return false;
    final parts = line.trim().replaceAll(RegExp(r'^\||\|$'), '').split('|');
    if (parts.length < 2) return false;
    return parts
        .map((p) => p.trim())
        .every((p) => RegExp(r'^:?-{3,}:?$').hasMatch(p));
  }

  bool _isLikelyMarkdownTableRow(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.contains('|')) return false;
    final parts = trimmed.replaceAll(RegExp(r'^\||\|$'), '').split('|');
    return parts.length >= 2;
  }

  String _normalizeMarkdownTableRow(String line) {
    final cells = line
        .trim()
        .replaceAll(RegExp(r'^\||\|$'), '')
        .split('|')
        .map((c) => _stripInlineMarkdown(c.trim()))
        .toList();
    return '| ${cells.join(' | ')} |';
  }

  List<String> _splitMarkdownTableCells(String line) {
    return line
        .trim()
        .replaceAll(RegExp(r'^\||\|$'), '')
        .split('|')
        .map((c) => c.trim())
        .toList();
  }

  List<_MarkdownTableBlock> _extractMarkdownTablesFromText(String text) {
    final lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final tables = <_MarkdownTableBlock>[];

    int i = 0;
    while (i < lines.length - 1) {
      if (_isLikelyMarkdownTableRow(lines[i]) &&
          i + 1 < lines.length &&
          _isMarkdownTableSeparator(lines[i + 1])) {
        final rows = <List<String>>[];
        rows.add(_splitMarkdownTableCells(lines[i]));

        int j = i + 2;
        while (j < lines.length &&
            _isLikelyMarkdownTableRow(lines[j]) &&
            !_isMarkdownTableSeparator(lines[j])) {
          rows.add(_splitMarkdownTableCells(lines[j]));
          j++;
        }

        final colCount = rows.fold<int>(0, (maxCols, row) {
          return row.length > maxCols ? row.length : maxCols;
        });

        final normalizedRows = rows.map((row) {
          final padded = List<String>.from(row);
          if (padded.length < colCount) {
            padded.addAll(List.filled(colCount - padded.length, ''));
          }
          return padded;
        }).toList();

        final endLine = (j - 1) >= (i + 1) ? (j - 1) : (i + 1);
        tables.add(
          _MarkdownTableBlock(
            startLine: i,
            endLine: endLine,
            rows: normalizedRows,
          ),
        );

        i = j;
        continue;
      }
      i++;
    }

    return tables;
  }

  List<String> _renderMarkdownTableLines(List<List<String>> rows) {
    if (rows.isEmpty) return const [];
    final colCount = rows.first.length;
    final normalizedRows = rows.map((row) {
      final normalized = List<String>.from(row);
      if (normalized.length < colCount) {
        normalized.addAll(List.filled(colCount - normalized.length, ''));
      }
      return normalized;
    }).toList();

    final output = <String>[];
    output.add('| ${normalizedRows.first.join(' | ')} |');
    output.add('| ${List.filled(colCount, '---').join(' | ')} |');
    for (final row in normalizedRows.skip(1)) {
      output.add('| ${row.join(' | ')} |');
    }
    return output;
  }

  void _replaceEditorText(String newText) {
    final normalized = newText.endsWith('\n') ? newText : '$newText\n';
    final selection = _controller.selection;
    var offset = selection.baseOffset;
    if (offset < 0) offset = 0;
    if (offset >= normalized.length) offset = normalized.length - 1;

    _controller.replaceText(
      0,
      _controller.document.length - 1,
      normalized,
      TextSelection.collapsed(offset: offset),
    );
  }

  void _updateTableCell(
    _MarkdownTableBlock table,
    int rowIndex,
    int colIndex,
    String value,
  ) {
    final plain = _controller.document.toPlainText();
    final lines = plain.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');

    if (table.startLine < 0 || table.endLine >= lines.length) return;
    if (rowIndex < 0 || rowIndex >= table.rows.length) return;
    if (colIndex < 0 || colIndex >= table.rows[rowIndex].length) return;

    final sanitized = value.replaceAll('|', '/').trim();
    final updatedRows = table.rows.map((row) => List<String>.from(row)).toList();
    updatedRows[rowIndex][colIndex] = sanitized;

    final replacementLines = _renderMarkdownTableLines(updatedRows);
    lines.replaceRange(table.startLine, table.endLine + 1, replacementLines);
    _replaceEditorText(lines.join('\n'));
    setState(() {});
  }

  Future<void> _promptEditTableCell(
    _MarkdownTableBlock table,
    int rowIndex,
    int colIndex,
  ) async {
    final controller = TextEditingController(text: table.rows[rowIndex][colIndex]);
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Edit Table Cell'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: null,
            decoration: const InputDecoration(
              hintText: 'Cell value',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );

    if (result != null) {
      _updateTableCell(table, rowIndex, colIndex, result);
    }
  }

  Widget _buildTableInspectorPanel() {
    final tables = _extractMarkdownTablesFromText(_controller.document.toPlainText());
    if (tables.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 270),
      decoration: BoxDecoration(
        color: const Color(0xFF131313),
        border: Border(top: BorderSide(color: Color(0xFF2E2E2E))),
      ),
      child: ListView.separated(
        padding: const EdgeInsets.all(8),
        itemCount: tables.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, tableIndex) {
          final table = tables[tableIndex];
          final headers = table.rows.first;
          final bodyRows = table.rows.length > 1
              ? table.rows.sublist(1)
              : [List.filled(headers.length, '')];

          return Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFF303030)),
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Editable Table ${tableIndex + 1} (tap cell to edit)',
                  style: const TextStyle(
                    color: Color(0xFF9AA0A6),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowColor: MaterialStateProperty.all(const Color(0xFF232323)),
                    dataRowColor: MaterialStateProperty.all(const Color(0xFF171717)),
                    columns: List.generate(headers.length, (colIndex) {
                      final label = headers[colIndex].isEmpty
                          ? 'Column ${colIndex + 1}'
                          : headers[colIndex];
                      return DataColumn(
                        label: InkWell(
                          onTap: () => _promptEditTableCell(table, 0, colIndex),
                          child: Row(
                            children: [
                              Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                              const SizedBox(width: 4),
                              const Icon(Icons.edit, size: 12, color: Color(0xFF8AB4F8)),
                            ],
                          ),
                        ),
                      );
                    }),
                    rows: List.generate(bodyRows.length, (rowOffset) {
                      final row = bodyRows[rowOffset];
                      final actualRowIndex = rowOffset + 1;
                      return DataRow(
                        cells: List.generate(headers.length, (colIndex) {
                          final value = colIndex < row.length ? row[colIndex] : '';
                          return DataCell(
                            InkWell(
                              onTap: () => _promptEditTableCell(table, actualRowIndex, colIndex),
                              child: Text(
                                value.isEmpty ? ' ' : value,
                                style: const TextStyle(color: Color(0xFFE8EAED)),
                              ),
                            ),
                          );
                        }),
                      );
                    }),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  String _markdownToPlainText(String markdown) {
    final lines = markdown
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final output = <String>[];

    int index = 0;
    while (index < lines.length) {
      final rawLine = lines[index];
      final line = rawLine.trimRight();
      if (line.trim().isEmpty) {
        output.add('');
        index++;
        continue;
      }

      final hasTableHeader = _isLikelyMarkdownTableRow(line);
      final hasTableDivider =
          index + 1 < lines.length && _isMarkdownTableSeparator(lines[index + 1]);
      if (hasTableHeader && hasTableDivider) {
        final headerCells = line
            .trim()
            .replaceAll(RegExp(r'^\||\|$'), '')
            .split('|')
            .map((c) => _stripInlineMarkdown(c.trim()))
            .toList();

        output.add('| ${headerCells.join(' | ')} |');
        output.add('| ${List.filled(headerCells.length, '---').join(' | ')} |');
        index += 2;

        while (index < lines.length && _isLikelyMarkdownTableRow(lines[index])) {
          if (_isMarkdownTableSeparator(lines[index])) {
            index++;
            continue;
          }
          output.add(_normalizeMarkdownTableRow(lines[index]));
          index++;
        }
        continue;
      }

      final h = RegExp(r'^#{1,6}\s+(.*)$').firstMatch(line);
      if (h != null) {
        output.add(_stripInlineMarkdown(h.group(1) ?? ''));
        index++;
        continue;
      }

      final ul = RegExp(r'^\s*[-*]\s+(.*)$').firstMatch(line);
      if (ul != null) {
        output.add('• ${_stripInlineMarkdown(ul.group(1) ?? '')}');
        index++;
        continue;
      }

      final ol = RegExp(r'^\s*(\d+)\.\s+(.*)$').firstMatch(line);
      if (ol != null) {
        output.add(
          '${ol.group(1)}. ${_stripInlineMarkdown(ol.group(2) ?? '')}',
        );
        index++;
        continue;
      }

      output.add(_stripInlineMarkdown(line));
      index++;
    }

    return output.join('\n').trim();
  }

  @override
  void initState() {
    super.initState();
    _initializeEditor();
    _controller.addListener(_onEditorChanged);
  }

  void _initializeEditor() {
    try {
      // Try to parse as JSON (Quill Delta format)
      final jsonContent = jsonDecode(widget.entry.content);
      final normalizedJson = _normalizeMathInDelta(jsonContent);
      _controller = quill.QuillController(
        document: quill.Document.fromJson(normalizedJson),
        selection: const TextSelection.collapsed(offset: 0),
      );
    } catch (e) {
      // If not JSON, clean markdown artifacts but preserve table rows for editing.
      final cleaned = _stripDuplicateChatQuestion(widget.entry.content);
      final mathNormalized = _normalizeMathMarkupForRender(cleaned);
      final normalized = _looksLikeMarkdown(mathNormalized)
          ? _markdownToPlainText(mathNormalized)
          : mathNormalized;
      final doc = quill.Document()..insert(0, normalized);
      _controller = quill.QuillController(
        document: doc,
        selection: const TextSelection.collapsed(offset: 0),
      );
    }
  }

  dynamic _normalizeMathInDelta(dynamic jsonDelta) {
    if (jsonDelta is! List) {
      return jsonDelta;
    }

    return jsonDelta.map((op) {
      if (op is Map && op['insert'] is String) {
        final mapped = Map<String, dynamic>.from(op as Map);
        final normalizedText = _normalizeMathMarkupForRender(
          mapped['insert'] as String,
        );

        if ((mapped['attributes'] == null ||
                (mapped['attributes'] is Map &&
                    (mapped['attributes'] as Map).isEmpty)) &&
            _looksLikeMarkdown(normalizedText)) {
          mapped['insert'] = _markdownToPlainText(normalizedText);
        } else {
          mapped['insert'] = normalizedText;
        }
        return mapped;
      }
      return op;
    }).toList();
  }

  String _previewMarkdown() {
    final plain = _controller.document.toPlainText();
    final withoutDupQ = _stripDuplicateChatQuestion(plain);
    final normalized = _normalizeMathMarkupForRender(withoutDupQ);
    return _convertMathInsideTableRowsForRender(normalized).trim();
  }

  @override
  void dispose() {
    _controller.removeListener(_onEditorChanged);
    _controller.dispose();
    _editorFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _insertTableTemplate() {
    const template =
        '| Column 1 | Column 2 | Column 3 |\n'
        '| --- | --- | --- |\n'
        '| Value 1 | Value 2 | Value 3 |\n';

    final selection = _controller.selection;
    if (selection.isValid) {
      final start = selection.start;
      final replaceLength = selection.end - selection.start;
      _controller.replaceText(
        start,
        replaceLength,
        template,
        TextSelection.collapsed(offset: start + template.length),
      );
    } else {
      final insertOffset = _controller.document.length - 1;
      _controller.replaceText(
        insertOffset,
        0,
        template,
        TextSelection.collapsed(offset: insertOffset + template.length),
      );
    }
  }

  Future<void> _saveNote() async {
    setState(() => _isSaving = true);
    try {
      // Save as JSON Delta format for rich text preservation
      final deltaJson = jsonEncode(_controller.document.toDelta().toJson());

      await StudioService.updateNotebookEntry(
        entryId: widget.entry.id,
        title: widget.entry.title,
        content: deltaJson,
      );

      widget.onUpdate();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Note saved successfully!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving note: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _downloadCurrentEntryPdf() async {
    try {
      final result = await StudioService.exportNotebookEntryPdf(
        entryId: widget.entry.id,
      );
      final saved = await _savePdfToDevice(
        dialogTitle: 'Save notebook entry PDF',
        fileName: result.filename,
        bytes: result.bytes,
      );
      if (!saved) return;

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Notebook entry PDF saved'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error exporting PDF: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Widget _buildEditorToolbar() {
    return Container(
      color: const Color(0xFF1E1E1E),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.bold,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.format_bold,
                tooltip: 'Bold',
              ),
            ),
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.italic,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.format_italic,
                tooltip: 'Italic',
              ),
            ),
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.underline,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.format_underline,
                tooltip: 'Underline',
              ),
            ),
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.strikeThrough,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.format_strikethrough,
                tooltip: 'Strikethrough',
              ),
            ),
            const VerticalDivider(),
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.h1,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.looks_one,
                tooltip: 'Heading 1',
              ),
            ),
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.h2,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.looks_two,
                tooltip: 'Heading 2',
              ),
            ),
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.h3,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.looks_3,
                tooltip: 'Heading 3',
              ),
            ),
            const VerticalDivider(),
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.ul,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.format_list_bulleted,
                tooltip: 'Bullet List',
              ),
            ),
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.ol,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.format_list_numbered,
                tooltip: 'Numbered List',
              ),
            ),
            quill.QuillToolbarToggleCheckListButton(
              controller: _controller,
              options: const quill.QuillToolbarToggleCheckListButtonOptions(
                iconData: Icons.check_box,
                tooltip: 'Checklist',
              ),
            ),
            const VerticalDivider(),
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.blockQuote,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.format_quote,
                tooltip: 'Quote',
              ),
            ),
            quill.QuillToolbarToggleStyleButton(
              attribute: quill.Attribute.codeBlock,
              controller: _controller,
              options: const quill.QuillToolbarToggleStyleButtonOptions(
                iconData: Icons.code,
                tooltip: 'Code Block',
              ),
            ),
            Tooltip(
              message: 'Insert Markdown Table',
              child: IconButton(
                onPressed: _insertTableTemplate,
                icon: const Icon(Icons.table_chart_outlined),
                color: Colors.white70,
                iconSize: 20,
                splashRadius: 20,
              ),
            ),
            const VerticalDivider(),
            quill.QuillToolbarIndentButton(
              controller: _controller,
              isIncrease: true,
              options: const quill.QuillToolbarIndentButtonOptions(
                iconData: Icons.format_indent_increase,
                tooltip: 'Increase Indent',
              ),
            ),
            quill.QuillToolbarIndentButton(
              controller: _controller,
              isIncrease: false,
              options: const quill.QuillToolbarIndentButtonOptions(
                iconData: Icons.format_indent_decrease,
                tooltip: 'Decrease Indent',
              ),
            ),
            const VerticalDivider(),
            quill.QuillToolbarLinkStyleButton(controller: _controller),
            quill.QuillToolbarClearFormatButton(
              controller: _controller,
              options: const quill.QuillToolbarClearFormatButtonOptions(
                iconData: Icons.format_clear,
                tooltip: 'Clear Format',
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewPane() {
    return Container(
      color: const Color(0xFF0D0D0D),
      padding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: MarkdownBody(
          data: _previewMarkdown(),
          selectable: true,
          inlineSyntaxes: [_BlockMathSyntaxStudio(), _InlineMathSyntaxStudio()],
          builders: {
            'math-inline': _MathElementBuilderStudio(isBlock: false),
            'math-block': _MathElementBuilderStudio(isBlock: true),
          },
          styleSheet: MarkdownStyleSheet(
            p: const TextStyle(
              fontSize: 15,
              height: 1.6,
              color: Color(0xFFE8EAED),
            ),
            tableHead: const TextStyle(
              fontSize: 15,
              height: 1.55,
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
            tableBody: const TextStyle(
              fontSize: 15,
              height: 1.7,
              color: Color(0xFFE8EAED),
            ),
            tableCellsPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            tableBorder: const TableBorder(
              horizontalInside: BorderSide(color: Color(0xFF3A3A3A), width: 0.8),
              verticalInside: BorderSide(color: Color(0xFF3A3A3A), width: 0.8),
              top: BorderSide(color: Color(0xFF5A5A5A), width: 0.9),
              bottom: BorderSide(color: Color(0xFF5A5A5A), width: 0.9),
              left: BorderSide(color: Color(0xFF5A5A5A), width: 0.9),
              right: BorderSide(color: Color(0xFF5A5A5A), width: 0.9),
            ),
            h1: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
            h2: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
            h3: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
            strong: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
            em: const TextStyle(
              fontStyle: FontStyle.italic,
              color: Color(0xFFE8EAED),
            ),
            listBullet: const TextStyle(
              fontSize: 15,
              height: 1.6,
              color: Color(0xFFE8EAED),
            ),
            code: const TextStyle(
              color: Color(0xFFE8EAED),
              backgroundColor: Color(0xFF1E1E1E),
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEditorPane(BuildContext context) {
    return Container(
      color: const Color(0xFF0D0D0D),
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Expanded(
            child: Theme(
              data: Theme.of(context).copyWith(
                textTheme: Theme.of(context).textTheme.apply(
                  bodyColor: Colors.white,
                  displayColor: Colors.white,
                ),
              ),
              child: quill.QuillEditor(
                controller: _controller,
                focusNode: _editorFocusNode,
                scrollController: _scrollController,
              ),
            ),
          ),
          _buildTableInspectorPanel(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        title: Text(widget.entry.title, style: const TextStyle(fontSize: 18)),
        backgroundColor: const Color(0xFF1E1E1E),
        actions: [
          IconButton(
            icon: Icon(
              _previewMode ? Icons.edit_outlined : Icons.visibility_outlined,
              color: const Color(0xFF8AB4F8),
            ),
            onPressed: () => setState(() => _previewMode = !_previewMode),
            tooltip: _previewMode ? 'Back to editor' : 'Formula preview',
          ),
          IconButton(
            icon: const Icon(
              Icons.picture_as_pdf_outlined,
              color: Color(0xFF8AB4F8),
            ),
            onPressed: _downloadCurrentEntryPdf,
            tooltip: 'Download as PDF',
          ),
          if (_isSaving)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Color(0xFF8AB4F8),
                    ),
                  ),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.save_outlined, color: Color(0xFF8AB4F8)),
              onPressed: _saveNote,
              tooltip: 'Save Note',
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!_previewMode) _buildEditorToolbar(),
            const Divider(height: 1, color: Color(0xFF333333)),
            Expanded(
              child: _previewMode
                  ? _buildPreviewPane()
                  : _buildEditorPane(context),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// FLASHCARDS TAB (Placeholder)
// ============================================================================

class FlashcardsTab extends StatelessWidget {
  final String spaceId;

  const FlashcardsTab({Key? key, required this.spaceId}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Flashcards coming soon...',
        style: TextStyle(color: Colors.grey, fontSize: 16),
      ),
    );
  }
}

// ============================================================================
// QUIZ TAB (Placeholder)
// ============================================================================

class QuizTab extends StatelessWidget {
  final String spaceId;

  const QuizTab({Key? key, required this.spaceId}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Quiz coming soon...',
        style: TextStyle(color: Colors.grey, fontSize: 16),
      ),
    );
  }
}
