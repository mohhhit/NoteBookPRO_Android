import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:io' show Platform;
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'providers/app_state.dart';
import 'services/api_service.dart';
import 'screens/settings_screen.dart';
import 'screens/studio_screen.dart';
import 'screens/splash_screen.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      await windowManager.ensureInitialized();
      
      WindowOptions windowOptions = const WindowOptions(
        size: Size(1280, 720),
        center: true,
        title: 'NotebookPRO',
      );
      
      windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
        await windowManager.setPreventClose(true);
      });
    }

    // Initialize ApiService to load saved backend URL
    await ApiService.initialize();
  } catch (e) {
    debugPrint('Initialization error: $e');
  }

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState()..initialize(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NotebookPRO',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0D0D0D),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF8AB4F8),
          surface: Color(0xFF1E1E1E),
          background: Color(0xFF0D0D0D),
        ),
        fontFamily: 'Google Sans',
      ),
      localizationsDelegates: const [
        FlutterQuillLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en', 'US')],
      home: SplashScreen(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _SendMessageIntent extends Intent {
  const _SendMessageIntent();
}

class _InlineMathSyntax extends md.InlineSyntax {
  _InlineMathSyntax() : super(r'\$([^$\n]+?)\$', startCharacter: 36);

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

class _BlockMathSyntax extends md.InlineSyntax {
  _BlockMathSyntax() : super(r'\$\$([\s\S]+?)\$\$', startCharacter: 36);

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

class _MathElementBuilder extends MarkdownElementBuilder {
  _MathElementBuilder({required this.isBlock});

  final bool isBlock;

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final expression = element.textContent.trim();
    if (expression.isEmpty) {
      return const SizedBox.shrink();
    }

    final baseStyle =
        preferredStyle ??
        const TextStyle(color: Color(0xFFE8EAED), fontSize: 15);
    final inlineFont = (((baseStyle.fontSize ?? 15) - 1).clamp(
      12,
      16,
    )).toDouble();
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
      onErrorFallback: (FlutterMathException e) =>
          Text(expression, style: effectiveStyle),
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

class _HomePageState extends State<HomePage> {
  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();
  int _bottomNavIndex = 1; // 0: Sources, 1: Chat, 2: Studio

  @override
  void initState() {
    super.initState();
    // Close sidebar by default on mobile
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final bool isMobile = MediaQuery.of(context).size.width < 600;
      if (isMobile) {
        context.read<AppState>().setSidebarOpen(false);
      }
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _messageFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _sendCurrentMessage(AppState appState) {
    if (appState.isThinking) {
      return;
    }

    final value = _messageController.text;
    if (value.trim().isEmpty) {
      return;
    }

    appState.sendMessage(value.trim());
    _messageController.clear();
  }

  void _prefillMessageInput(String question) {
    _messageController.text = question;
    _messageController.selection = TextSelection.fromPosition(
      TextPosition(offset: _messageController.text.length),
    );
    _messageFocusNode.requestFocus();
  }

  String _latexToReadableText(String expr) {
    var out = expr;
    out = out.replaceAllMapped(
      RegExp(r'\\frac\{([^{}]+)\}\{([^{}]+)\}'),
      (m) => '(${m.group(1)})/(${m.group(2)})',
    );

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
      r'\approx': '~',
    };

    replacements.forEach((k, v) {
      out = out.replaceAll(k, v);
    });

    out = out.replaceAll('{', '').replaceAll('}', '');
    out = out.replaceAll(r'\(', '(').replaceAll(r'\)', ')');
    out = out.replaceAll(r'\[', '[').replaceAll(r'\]', ']');
    out = out.replaceAllMapped(RegExp(r'\\([A-Za-z]+)'), (m) => m.group(1)!);
    out = out.replaceAll('\\', '');
    out = out.replaceAll(RegExp(r'\s+'), ' ').trim();
    return out;
  }

  String _convertMathInsideTableRows(String input) {
    final lines = input
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final out = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      final isTableLike =
          trimmed.startsWith('|') &&
          trimmed.endsWith('|') &&
          trimmed.split('|').length >= 3;
      if (!isTableLike) {
        out.add(line);
        continue;
      }

      var converted = line;
      converted = converted.replaceAllMapped(
        RegExp(r'\$\$([\s\S]+?)\$\$'),
        (m) => _latexToReadableText((m.group(1) ?? '').trim()),
      );
      converted = converted.replaceAllMapped(
        RegExp(r'\$([^$\n]+?)\$'),
        (m) => _latexToReadableText((m.group(1) ?? '').trim()),
      );
      out.add(converted);
    }

    return out.join('\n');
  }

  String _normalizeMathMarkup(String text) {
    var normalized = text;
    normalized = normalized.replaceAll(r'\$', r'$');
    normalized = normalized.replaceAll('\\\\', '\\');
    normalized = normalized.replaceAllMapped(
      RegExp(r'\\\[([\s\S]*?)\\\]'),
      (m) => '\n\$\$${(m.group(1) ?? '').trim()}\$\$\n',
    );
    normalized = normalized.replaceAllMapped(
      RegExp(r'\\\(([^\n]*?)\\\)'),
      (m) => '\n\$${(m.group(1) ?? '').trim()}\$\n',
    );
    normalized = normalized.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    normalized = _convertMathInsideTableRows(normalized);
    return normalized;
  }

  @override
  Widget build(BuildContext context) {
    final bool isMobile = MediaQuery.of(context).size.width < 600;

    return Consumer<AppState>(
      builder: (context, appState, _) {
        return Scaffold(
          body: SafeArea(
            child: GestureDetector(
              onTap: () => appState.closeMenus(),
              child: Stack(
                children: [
                  // Base Layout
                  Row(
                    children: [
                      // Desktop Sidebar (Side-by-side)
                      if (appState.sidebarOpen && !isMobile)
                        Container(
                          width: 260,
                          decoration: const BoxDecoration(
                            color: Color(0xFF131314),
                            border: Border(
                              right: BorderSide(color: Color(0xFF2D2D2D)),
                            ),
                          ),
                          child: Material(
                            type: MaterialType.transparency,
                            child: _buildSidebar(appState, isMobile: false),
                          ),
                        ),

                      // Main content
                      Expanded(
                        child: Stack(
                          children: [
                            Column(
                              children: [
                                if (_bottomNavIndex != 2)
                                  _buildTopBar(appState),

                                // Main tab content
                                Expanded(child: _buildMainTabContent(appState)),

                                // Chat input (only in chat tab)
                                if (_bottomNavIndex == 1)
                                  _buildInputArea(appState),

                                // Bottom navigation
                                _buildBottomNavigationBar(appState),
                              ],
                            ),

                            // Error snackbar
                            if (appState.error != null)
                              Positioned(
                                top: 8,
                                left: 16,
                                right: 16,
                                child: Material(
                                  color: Colors.red.shade900,
                                  borderRadius: BorderRadius.circular(12),
                                  elevation: 8,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.error,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            appState.error!,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 13,
                                            ),
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.close,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () =>
                                              appState.clearError(),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),

                            // Success message banner
                            if (appState.successMessage != null)
                              Positioned(
                                top: 8,
                                left: 16,
                                right: 16,
                                child: Material(
                                  color: Colors.green.shade800,
                                  borderRadius: BorderRadius.circular(12),
                                  elevation: 8,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.check_circle,
                                          color: Colors.white,
                                          size: 20,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            appState.successMessage!,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w500,
                                              fontSize: 13,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.close,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                          padding: EdgeInsets.zero,
                                          constraints: const BoxConstraints(),
                                          onPressed: () =>
                                              appState.clearSuccessMessage(),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),

                            // Upload loading overlay
                            if (appState.isUploading)
                              Positioned.fill(
                                child: Container(
                                  color: Colors.black87,
                                  child: Center(
                                    child: Card(
                                      color: const Color(0xFF2D2D2D),
                                      child: Container(
                                        width: isMobile
                                            ? MediaQuery.of(
                                                    context,
                                                  ).size.width *
                                                  0.85
                                            : 400,
                                        padding: const EdgeInsets.all(32),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const CircularProgressIndicator(
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    Color(0xFF8AB4F8),
                                                  ),
                                              strokeWidth: 3,
                                            ),
                                            const SizedBox(height: 24),
                                            const Text(
                                              'Processing Documents',
                                              style: TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            const SizedBox(height: 16),

                                            // Progress bar
                                            ClipRRect(
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              child: LinearProgressIndicator(
                                                backgroundColor: const Color(
                                                  0xFF1A1A1A,
                                                ),
                                                valueColor:
                                                    const AlwaysStoppedAnimation<
                                                      Color
                                                    >(Color(0xFF8AB4F8)),
                                                minHeight: 6,
                                              ),
                                            ),

                                            const SizedBox(height: 20),

Text(appState.uploadStatus.isEmpty ? 'Please wait...' : appState.uploadStatus, style: const TextStyle(color: Colors.white70, fontSize: 14), textAlign: TextAlign.center),
],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),

                  // Mobile Sidebar Overlay (Appears on TOP)
                  if (appState.sidebarOpen && isMobile)
                    Positioned.fill(
                      child: Stack(
                        children: [
                          // Dimmed background
                          GestureDetector(
                            onTap: () => appState.toggleSidebar(),
                            child: Container(color: Colors.black54),
                          ),
                          // Sidebar content
                          Material(
                            elevation: 16,
                            child: Container(
                              width: 280,
                              height: double.infinity,
                              decoration: const BoxDecoration(
                                color: Color(0xFF131314),
                                border: Border(
                                  right: BorderSide(color: Color(0xFF2D2D2D)),
                                ),
                              ),
                              child: Material(
                                type: MaterialType.transparency,
                                child: _buildSidebar(appState, isMobile: true),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSidebar(AppState appState, {required bool isMobile}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Logo
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/app_icon.png',
                  width: 32,
                  height: 32,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'NotebookPRO',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              if (isMobile) const Spacer(),
              if (isMobile)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => appState.toggleSidebar(),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        // Spaces
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            'SPACES',
            style: TextStyle(
              fontSize: 11,
              color: Color(0xFF9AA0A6),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),

        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              for (final space in appState.spaces) ...[
                ListTile(
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.folder, size: 20),
                      if (space.fileCount > 0)
                        Positioned(
                          right: -6,
                          top: -6,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: const Color(0xFF8AB4F8),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            constraints: const BoxConstraints(
                              minWidth: 16,
                              minHeight: 16,
                            ),
                            child: Text(
                              space.fileCount.toString(),
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 9,
                                fontWeight: FontWeight.bold,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                    ],
                  ),
                  title: Text(space.name, style: const TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '${space.fileCount} file${space.fileCount != 1 ? 's' : ''}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9AA0A6),
                    ),
                  ),
                  selected: appState.currentSpace?.id == space.id,
                  selectedTileColor: const Color(0xFF1E3A5F),
                  onTap: () async {
                    if (appState.currentSpace?.id != space.id) {
                      await appState.selectSpace(space.id);
                    } else {
                      appState.toggleSpaceExpansion(space.id);
                    }
                  },
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        appState.isSpaceExpanded(space.id)
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                        color: const Color(0xFF9AA0A6),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, size: 18),
                        onPressed: () => appState.deleteSpace(space.id),
                      ),
                    ],
                  ),
                ),

                if (appState.isSpaceExpanded(space.id))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 12, 8),
                    child: OutlinedButton.icon(
                      onPressed: () {
                        appState.newChat();
                        if (isMobile) appState.toggleSidebar();
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('New Chat'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 36),
                        side: const BorderSide(color: Color(0xFF3C4043)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                    ),
                  ),

                if (appState.isSpaceExpanded(space.id) &&
                    appState.chats.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(28, 0, 16, 10),
                    child: Text(
                      'No chats yet',
                      style: TextStyle(color: Color(0xFF9AA0A6), fontSize: 12),
                    ),
                  ),

                if (appState.isSpaceExpanded(space.id))
                  ...appState.chats.asMap().entries.map((entry) {
                    final chat = entry.value;
                    return Container(
                      margin: const EdgeInsets.only(left: 20, right: 4),
                      decoration: const BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: Color(0xFF2D2D2D),
                            width: 1,
                          ),
                        ),
                      ),
                      child: ListTile(
                        dense: false,
                        leading: const Icon(
                          Icons.chat_bubble_outline,
                          size: 16,
                        ),
                        title: Text(
                          chat.title,
                          maxLines: 2,
                          softWrap: true,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        onTap: () async {
                          await appState.loadChat(chat.id);
                          if (isMobile) appState.toggleSidebar();
                        },
                        selected: appState.currentChat?.id == chat.id,
                        selectedTileColor: const Color(0xFF1E3A5F),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete, size: 16),
                          onPressed: () => appState.deleteChat(chat.id),
                        ),
                      ),
                    );
                  }),

                if (appState.isSpaceExpanded(space.id))
                  const Divider(color: Color(0xFF2D2D2D), height: 12),
              ],

              // Add space button
              Padding(
                padding: const EdgeInsets.all(12),
                child: OutlinedButton.icon(
                  onPressed: () => _showCreateSpaceDialog(appState),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('New Space'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 40),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(AppState appState) {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF2D2D2D))),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => appState.toggleSidebar(),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              appState.currentSpace?.name ?? 'No Space Selected',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),

          // Action Menu
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            color: const Color(0xFF2D2D2D),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onSelected: (value) {
              switch (value) {
                case 'settings':
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const SettingsScreen(),
                    ),
                  );
                  break;
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings, size: 20),
                    SizedBox(width: 12),
                    Text('Settings'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMainTabContent(AppState appState) {
    if (_bottomNavIndex == 0) {
      return _buildSourcesScreen(appState);
    }

    if (_bottomNavIndex == 2) {
      if (appState.currentSpace == null) {
        return const Center(
          child: Text(
            'Select a space to open Studio',
            style: TextStyle(color: Color(0xFF9AA0A6), fontSize: 14),
          ),
        );
      }

      return StudioScreen(
        spaceId: appState.currentSpace!.id,
        spaceName: appState.currentSpace!.name,
      );
    }

    return appState.currentChat == null
        ? _buildWelcomeScreen(appState)
        : _buildChatMessages(appState);
  }

  Widget _buildBottomNavigationBar(AppState appState) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFF2D2D2D))),
      ),
      child: BottomNavigationBar(
        currentIndex: _bottomNavIndex,
        type: BottomNavigationBarType.fixed,
        backgroundColor: const Color(0xFF131314),
        selectedItemColor: const Color(0xFF8AB4F8),
        unselectedItemColor: const Color(0xFF9AA0A6),
        onTap: (index) async {
          setState(() => _bottomNavIndex = index);
          appState.closeMenus();

          if (index == 0 && appState.currentSpace != null) {
            await appState.loadUploadedFiles();
          }
        },
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.menu_book_outlined),
            activeIcon: Icon(Icons.menu_book),
            label: 'Sources',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            activeIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.auto_awesome_outlined),
            activeIcon: Icon(Icons.auto_awesome),
            label: 'Studio',
          ),
        ],
      ),
    );
  }

  Widget _buildSourcesScreen(AppState appState) {
    final files = appState.uploadedFiles;

    IconData iconForFilename(String filename) {
      if (filename.endsWith('.pdf')) return Icons.picture_as_pdf;
      if (filename.endsWith('.docx') || filename.endsWith('.doc'))
        return Icons.description;
      if (filename.endsWith('.txt')) return Icons.text_snippet;
      return Icons.insert_drive_file;
    }

    Color colorForFilename(String filename) {
      if (filename.endsWith('.pdf')) return Colors.red.shade400;
      if (filename.endsWith('.docx') || filename.endsWith('.doc'))
        return Colors.blue.shade400;
      if (filename.endsWith('.txt')) return Colors.green.shade400;
      return Colors.grey.shade400;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            children: [
              const Text(
                'Sources',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E3A5F),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${files.length}',
                  style: const TextStyle(
                    color: Color(0xFF8AB4F8),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: appState.currentSpace == null
                    ? null
                    : () => _uploadFiles(appState),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add source'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8AB4F8),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(color: Color(0xFF2D2D2D), height: 1),
        Expanded(
          child: files.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.folder_open,
                        size: 64,
                        color: Colors.grey.shade700,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        appState.currentSpace == null
                            ? 'Select a space to view sources'
                            : 'No sources yet',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  itemCount: files.length,
                  separatorBuilder: (_, __) => const Divider(
                    color: Color(0xFF2D2D2D),
                    height: 1,
                    indent: 56,
                  ),
                  itemBuilder: (context, index) {
                    final file = files[index];
                    final filename = file['filename'] ?? 'Unknown';
                    final chunks = file['chunks'] ?? 0;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      leading: Icon(
                        iconForFilename(filename),
                        color: colorForFilename(filename),
                        size: 26,
                      ),
                      title: Text(
                        filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('$chunks chunks'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        color: Colors.red.shade300,
                        onPressed: () => appState.deleteFile(filename),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildWelcomeScreen(AppState appState) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [
                  Color(0xFF4285F4),
                  Color(0xFFEA4335),
                  Color(0xFFFBBC05),
                  Color(0xFF34A853),
                ],
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Icon(
              Icons.auto_awesome,
              size: 40,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Hello!',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.w300),
          ),
          const SizedBox(height: 8),
          const Text(
            'How can I help you today?',
            style: TextStyle(fontSize: 16, color: Color(0xFF9AA0A6)),
          ),
        ],
      ),
    );
  }

  double _readableChatColumnMaxWidth(BuildContext context) {
    final media = MediaQuery.of(context);
    final width = media.size.width;
    final isLandscape = media.orientation == Orientation.landscape;

    if (!isLandscape || width < 600) {
      return width;
    }

    const geminiLandscapeColumnWidth = 760.0;
    return (width - 24).clamp(0, geminiLandscapeColumnWidth).toDouble();
  }

  Widget _centeredReadableChatItem(BuildContext context, Widget child) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: _readableChatColumnMaxWidth(context),
        ),
        child: child,
      ),
    );
  }

  Widget _buildChatMessages(AppState appState) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    final messages = appState.currentChat!.messages;
    final isMobile = MediaQuery.of(context).size.width < 600;
    final hasPendingAssistant =
        messages.isNotEmpty &&
        messages.last.role == 'assistant' &&
        messages.last.content.trim().isEmpty;

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      itemCount:
          messages.length +
          ((appState.isThinking && !hasPendingAssistant) ? 1 : 0),
      itemBuilder: (context, index) {
        // Show thinking indicator as last item
        if (index == messages.length) {
          return _centeredReadableChatItem(
            context,
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'NotebookPRO',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: Color(0xFF9AA0A6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: const [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xFF8AB4F8),
                          ),
                        ),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Thinking...',
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: Color(0xFF9AA0A6),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }

        final message = messages[index];
        final isUser = message.role == 'user';
        final displayContent = isUser
            ? message.content
            : _stripInlineDocumentReferences(message.content);
        final citationNumbers = isUser
            ? const <int>[]
            : _extractDocumentReferenceNumbers(message.content);

        if (!isUser &&
            message.content.trim().isEmpty &&
            appState.isThinking &&
            index == messages.length - 1) {
          return _centeredReadableChatItem(
            context,
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'NotebookPRO',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      color: Color(0xFF9AA0A6),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: const [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xFF8AB4F8),
                          ),
                        ),
                      ),
                      SizedBox(width: 10),
                      Text(
                        'Thinking...',
                        style: TextStyle(
                          fontSize: 15,
                          height: 1.5,
                          color: Color(0xFF9AA0A6),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }

        if (isUser) {
          return _centeredReadableChatItem(
            context,
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isMobile
                        ? MediaQuery.of(context).size.width * 0.84
                        : 620,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1F2A3A),
                      border: Border.all(color: const Color(0xFF35527A)),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      displayContent,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.left,
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return _centeredReadableChatItem(
          context,
          Padding(
            padding: const EdgeInsets.only(bottom: 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      'NotebookPRO',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        color: Color(0xFF9AA0A6),
                      ),
                    ),
                    const Spacer(),
                    PopupMenuButton<String>(
                      icon: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: Colors.grey[400],
                      ),
                      color: const Color(0xFF2D2D2D),
                      tooltip: 'Message options',
                      onSelected: (value) async {
                        final question = _findRelatedQuestion(
                          appState.currentChat!.messages,
                          index,
                        );

                        if (value == 'add_to_notebook') {
                          await appState.addAssistantReplyToNotebook(
                            question: question,
                            answer: message.content,
                            assistantTimestamp: message.timestamp,
                            tags: const ['chat', 'saved_from_reply'],
                          );
                        }
                      },
                      itemBuilder: (context) => const [
                        PopupMenuItem<String>(
                          value: 'add_to_notebook',
                          child: Row(
                            children: [
                              Icon(
                                Icons.bookmark_add_outlined,
                                size: 18,
                                color: Colors.white,
                              ),
                              SizedBox(width: 8),
                              Text('Add to notebook'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                MarkdownBody(
                  data: _normalizeMathMarkup(displayContent),
                  selectable: true,
                  extensionSet: md.ExtensionSet.gitHubFlavored,
                  inlineSyntaxes: [_BlockMathSyntax(), _InlineMathSyntax()],
                  builders: {
                    'math-inline': _MathElementBuilder(isBlock: false),
                    'math-block': _MathElementBuilder(isBlock: true),
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
                    tableBorder: TableBorder(
                      horizontalInside: BorderSide(
                        color: Color(0xFF3A3A3A),
                        width: 0.8,
                      ),
                      verticalInside: BorderSide(
                        color: Color(0xFF3A3A3A),
                        width: 0.8,
                      ),
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
                    h4: const TextStyle(
                      fontSize: 16,
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
                    blockquote: const TextStyle(
                      fontSize: 14,
                      height: 1.6,
                      color: Color(0xFFB0BEC5),
                      fontStyle: FontStyle.italic,
                    ),
                    code: TextStyle(
                      fontSize: 13,
                      color: Colors.green.shade200,
                      backgroundColor: const Color(0xFF1A1A1A),
                    ),
                  ),
                ),
                if (citationNumbers.isNotEmpty)
                  _buildCitationLinks(
                    context,
                    citationNumbers,
                    message.sources,
                  ),
                if ((message.suggestedFollowUps ?? const <String>[]).isNotEmpty)
                  _buildSuggestedFollowUps(
                    appState,
                    message.suggestedFollowUps!,
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 2,
                    runSpacing: 4,
                    children: [
                      IconButton(
                        onPressed: () async {
                          final question = _findRelatedQuestion(
                            appState.currentChat!.messages,
                            index,
                          );
                          final payload =
                              'Q: $question\n\nA: ${message.content}';
                          await Clipboard.setData(ClipboardData(text: payload));
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Chat copied to clipboard'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(Icons.copy_outlined, size: 18),
                        color: const Color(0xFF9AA0A6),
                        tooltip: 'Copy chat',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: const EdgeInsets.all(6),
                      ),
                      IconButton(
                        onPressed: appState.isThinking
                            ? null
                            : () async {
                                final question = _findRelatedQuestion(
                                  appState.currentChat!.messages,
                                  index,
                                );
                                await appState.sendMessage(question);
                              },
                        icon: const Icon(Icons.refresh, size: 18),
                        color: const Color(0xFF8AB4F8),
                        tooltip: 'Regenerate response',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: const EdgeInsets.all(6),
                      ),
                      IconButton(
                        onPressed: appState.isThinking
                            ? null
                            : () async {
                                final shouldDelete =
                                    await _confirmDeleteResponse(context);
                                if (!shouldDelete) return;
                                await appState.deleteAssistantResponse(
                                  messageIndex: index,
                                );
                              },
                        icon: const Icon(Icons.delete_outline, size: 18),
                        color: Colors.red.shade300,
                        tooltip: 'Delete Q&A',
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        padding: const EdgeInsets.all(6),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _findRelatedQuestion(List<dynamic> messages, int assistantIndex) {
    for (int i = assistantIndex - 1; i >= 0; i--) {
      if (messages[i].role == 'user') {
        return messages[i].content;
      }
    }
    return 'Question from chat';
  }

  Future<bool> _confirmDeleteResponse(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Delete question and response?'),
          content: const Text(
            'This will remove this question and its assistant response from the current chat.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(
                'Delete',
                style: TextStyle(color: Colors.redAccent),
              ),
            ),
          ],
        );
      },
    );

    return result ?? false;
  }

  String _stripInlineDocumentReferences(String text) {
    // Matches (Document 1), (Document 1, Document 2)
    final docRefs = RegExp(
      r'\s*\((?:Document\s+\d+)(?:\s*,\s*Document\s+\d+)*\)',
      caseSensitive: false,
    );
    // Matches [1], [1, 2], [1] [2], **[1]**, [10]
    final bracketRefs = RegExp(
      r'\s*(?:\*\*)?\[\d+(?:\s*,\s*\d+)*\](?:\*\*)?',
      caseSensitive: false,
    );

    String stripped = text.replaceAll(docRefs, '').replaceAll(bracketRefs, '');
    final compactSpaces = stripped.replaceAll(RegExp(r' {2,}'), ' ');
    return compactSpaces.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  List<int> _extractDocumentReferenceNumbers(String text) {
    final seen = <int>{};
    final refs = <int>[];

    // Extract from Document X
    final docMatches = RegExp(
      r'Document\s+(\d+)',
      caseSensitive: false,
    ).allMatches(text);
    for (final match in docMatches) {
      final value = int.tryParse(match.group(1) ?? '');
      if (value != null && seen.add(value)) {
        refs.add(value);
      }
    }

    // Extract from [X] or **[X]**
    final bracketMatches = RegExp(r'\[(\d+)\]').allMatches(text);
    for (final match in bracketMatches) {
      final value = int.tryParse(match.group(1) ?? '');
      if (value != null && seen.add(value)) {
        refs.add(value);
      }
    }

    // Sort references numerically
    refs.sort();
    return refs;
  }

  Widget _buildCitationLinks(
    BuildContext context,
    List<int> citationNumbers,
    List<dynamic>? sources,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: citationNumbers.map((docNumber) {
          final source =
              (sources != null &&
                  docNumber - 1 >= 0 &&
                  docNumber - 1 < sources.length)
              ? sources[docNumber - 1]
              : null;

          return InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: source == null
                ? null
                : () => _showCitationDetails(context, docNumber, source),
            child: Transform.translate(
              offset: const Offset(0, -2),
              child: Text(
                '[$docNumber]',
                style: TextStyle(
                  fontSize: 11,
                  color: source == null
                      ? const Color(0xFF9AA0A6)
                      : const Color(0xFF8AB4F8),
                  decoration: source == null
                      ? TextDecoration.none
                      : TextDecoration.underline,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildSuggestedFollowUps(AppState appState, List<String> suggestions) {
    final visibleSuggestions = suggestions
        .where((q) => q.trim().isNotEmpty)
        .take(4)
        .toList();

    if (visibleSuggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Suggested follow-up questions',
                style: TextStyle(
                  color: Color(0xFF9AC7B5),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ...visibleSuggestions.map((question) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: appState.isThinking
                          ? null
                          : () {
                              _prefillMessageInput(question);
                            },
                      child: Container(
                        width: constraints.maxWidth,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF13211D),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF2F7A5C)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(top: 1),
                              child: Icon(
                                Icons.auto_awesome,
                                size: 14,
                                color: Color(0xFF6FD0A7),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                question,
                                softWrap: true,
                                overflow: TextOverflow.visible,
                                style: const TextStyle(
                                  color: Color(0xFFE6F4EE),
                                  fontSize: 13,
                                  height: 1.3,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }

  void _showCitationDetails(
    BuildContext context,
    int docNumber,
    dynamic source,
  ) {
    final metadata = source is Map<String, dynamic>
        ? (source['metadata'] as Map<String, dynamic>?)
        : null;
    final filename = metadata?['filename']?.toString() ?? 'Unknown source';
    final snippet = source is Map<String, dynamic>
        ? (source['content']?.toString() ?? 'No snippet available.')
        : 'No snippet available.';
    final score = source is Map<String, dynamic> ? source['score'] : null;

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Citation [$docNumber]',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                filename,
                style: const TextStyle(
                  color: Color(0xFF8AB4F8),
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (score != null) ...[
                const SizedBox(height: 6),
                Text(
                  'Relevance score: ${score.toString()}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF9AA0A6),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: SelectableText(
                    snippet,
                    style: const TextStyle(fontSize: 14, height: 1.45),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInputArea(AppState appState) {
    final viewportWidth = MediaQuery.of(context).size.width;
    final isMobile = viewportWidth < 600;
    final maxInputWidth = isMobile
        ? viewportWidth
        : _readableChatColumnMaxWidth(context) + 90;

    return Container(
      padding: EdgeInsets.fromLTRB(
        isMobile ? 12 : 16,
        12,
        isMobile ? 12 : 16,
        16,
      ),
      child: Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxInputWidth),
          child: Row(
            children: [
              // Input field
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 720),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFF3C4043)),
                  ),
                  child: Shortcuts(
                    shortcuts: const <ShortcutActivator, Intent>{
                      SingleActivator(LogicalKeyboardKey.enter):
                          _SendMessageIntent(),
                      SingleActivator(LogicalKeyboardKey.numpadEnter):
                          _SendMessageIntent(),
                    },
                    child: Actions(
                      actions: <Type, Action<Intent>>{
                        _SendMessageIntent: CallbackAction<_SendMessageIntent>(
                          onInvoke: (_) {
                            _sendCurrentMessage(appState);
                            return null;
                          },
                        ),
                      },
                      child: TextField(
                        controller: _messageController,
                        focusNode: _messageFocusNode,
                        minLines: 1,
                        maxLines: 5,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        decoration: const InputDecoration(
                          hintText: 'Ask anything...',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(width: 12),

              // Send button
              Container(
                decoration: BoxDecoration(
                  color: appState.isThinking
                      ? const Color(0xFF2D2D2D)
                      : const Color(0xFF8AB4F8),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: IconButton(
                  icon: const Icon(Icons.send_rounded, size: 20),
                  color: appState.isThinking
                      ? const Color(0xFF9AA0A6)
                      : Colors.black,
                  tooltip: 'Send',
                  onPressed: appState.isThinking
                      ? null
                      : () => _sendCurrentMessage(appState),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlusMenu(AppState appState) {
    final fileCount = appState.uploadedFiles.length;

    return Material(
      color: const Color(0xFF2D2D2D),
      borderRadius: BorderRadius.circular(12),
      elevation: 8,
      child: Container(
        width: 220,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.description, size: 20),
              title: const Text('Files', style: TextStyle(fontSize: 14)),
              trailing: fileCount > 0
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF8AB4F8),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        fileCount.toString(),
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  : const Text(
                      '0',
                      style: TextStyle(color: Color(0xFF9AA0A6), fontSize: 11),
                    ),
              onTap: () {
                appState.closeMenus();
                appState.toggleFilesDrawer();
              },
            ),
            _menuItem(Icons.upload_file, 'Upload Files', () {
              appState.closeMenus();
              _uploadFiles(appState);
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildToolsMenu(AppState appState) {
    return Material(
      color: const Color(0xFF2D2D2D),
      borderRadius: BorderRadius.circular(12),
      elevation: 8,
      child: Container(
        width: 160,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _menuItem(
              Icons.chat,
              'Chat',
              () => appState.setActiveTool('Chat'),
              selected: appState.activeTool == 'Chat',
            ),
            _menuItem(
              Icons.summarize,
              'Summarize',
              () => appState.setActiveTool('Summarize'),
              selected: appState.activeTool == 'Summarize',
            ),
          ],
        ),
      ),
    );
  }

  Widget _menuItem(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool selected = false,
  }) {
    return ListTile(
      dense: true,
      leading: Icon(icon, size: 20),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      trailing: selected ? const Icon(Icons.check, size: 18) : null,
      onTap: onTap,
    );
  }

  Widget _buildProcessingStep(String emoji, String text, bool isActive) {
    return Row(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 16)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 14,
              color: isActive ? Colors.white : Colors.grey.shade600,
              fontWeight: isActive ? FontWeight.w500 : FontWeight.normal,
            ),
          ),
        ),
        if (isActive)
          Container(
            width: 16,
            height: 16,
            margin: const EdgeInsets.only(left: 8),
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.grey.shade400),
            ),
          ),
      ],
    );
  }

  Future<void> _uploadFiles(AppState appState) async {
    FilePickerResult? result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['pdf', 'txt', 'docx'],
      withData: false, // Must be false on Android to prevent Java OOM
    );

    if (result != null && result.files.isNotEmpty) {
      await appState.uploadFiles(result.files);
    }
  }

  Future<void> _showCreateSpaceDialog(AppState appState) async {
    final controller = TextEditingController();

    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF2D2D2D),
        title: const Text('Create New Space'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Space name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                appState.createSpace(controller.text.trim());
                Navigator.pop(context);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilesDrawer(AppState appState) {
    return GestureDetector(
      onTap: () {}, // Prevent closing when tapping inside drawer
      child: Container(
        width: 320,
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E1E),
          border: Border(left: BorderSide(color: Color(0xFF2D2D2D))),
          boxShadow: [
            BoxShadow(
              color: Colors.black45,
              blurRadius: 10,
              offset: Offset(-2, 0),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFF2D2D2D))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.description, color: Color(0xFF8AB4F8)),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Uploaded Files',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => appState.toggleFilesDrawer(),
                  ),
                ],
              ),
            ),

            // File count summary
            Container(
              padding: const EdgeInsets.all(16),
              color: const Color(0xFF131314),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E3A5F),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${appState.uploadedFiles.length} files',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8AB4F8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'in ${appState.currentSpace?.name ?? "this space"}',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),

            // Files list
            Expanded(
              child: appState.uploadedFiles.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.folder_open,
                            size: 64,
                            color: Colors.grey.shade700,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No files uploaded yet',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: appState.uploadedFiles.length,
                      itemBuilder: (context, index) {
                        final file = appState.uploadedFiles[index];
                        final filename = file['filename'] ?? 'Unknown';
                        final chunks = file['chunks'] ?? 0;

                        // Determine file icon based on extension
                        IconData fileIcon = Icons.insert_drive_file;
                        Color fileColor = Colors.grey.shade400;
                        if (filename.endsWith('.pdf')) {
                          fileIcon = Icons.picture_as_pdf;
                          fileColor = Colors.red.shade400;
                        } else if (filename.endsWith('.docx') ||
                            filename.endsWith('.doc')) {
                          fileIcon = Icons.description;
                          fileColor = Colors.blue.shade400;
                        } else if (filename.endsWith('.txt')) {
                          fileIcon = Icons.text_snippet;
                          fileColor = Colors.green.shade400;
                        }

                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          color: const Color(0xFF2D2D2D),
                          child: ListTile(
                            dense: true,
                            leading: Icon(fileIcon, color: fileColor, size: 24),
                            title: Text(
                              filename,
                              style: const TextStyle(fontSize: 13),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '$chunks chunks',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500,
                              ),
                            ),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete, size: 18),
                              color: Colors.red.shade400,
                              tooltip: 'Delete file',
                              onPressed: () {
                                // Show confirmation dialog
                                showDialog(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Delete File?'),
                                    content: Text(
                                      'Are you sure you want to delete "$filename"? This will remove all its chunks from the knowledge base.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () {
                                          Navigator.pop(context);
                                          appState.deleteFile(filename);
                                        },
                                        style: TextButton.styleFrom(
                                          foregroundColor: Colors.red,
                                        ),
                                        child: const Text('Delete'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

