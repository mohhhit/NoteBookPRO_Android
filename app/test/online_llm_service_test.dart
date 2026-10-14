import 'package:flutter_test/flutter_test.dart';
import 'package:notebook_pro_app/services/online_llm_service.dart';
import 'package:notebook_pro_app/providers/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OnlineLlmService - Model Configuration', () {
    test('contains gemini-3.5-flash-lite exclusively', () {
      final modelIds = OnlineLlmService.supportedModels.map((m) => m['id']).toList();
      expect(modelIds.length, equals(1));
      expect(modelIds.first, equals('gemini-3.5-flash-lite'));
    });

    test('getModelDisplayName returns gemini3.5-flash-lite', () {
      expect(OnlineLlmService.getModelDisplayName('gemini-3.5-flash-lite'), equals('gemini3.5-flash-lite'));
      expect(OnlineLlmService.getModelDisplayName('gemini3.5-flash-lite'), equals('gemini3.5-flash-lite'));
    });
  });

  group('AppState - Online/Offline LLM Mode Switching', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to offline mode and allows switching to online', () async {
      final appState = AppState();
      await appState.loadLlmSettings();

      expect(appState.useOnlineLlm, isFalse);
      expect(appState.activeModelDisplayName, equals('Gemma 4 E2B'));

      await appState.setGeminiApiKey('AIzaSyTestKey123');
      expect(appState.geminiApiKey, equals('AIzaSyTestKey123'));

      await appState.setUseOnlineLlm(true);
      expect(appState.useOnlineLlm, isTrue);
      expect(appState.activeModelDisplayName, equals('gemini3.5-flash-lite'));

      await appState.setOnlineModelName('gemini-3.5-flash-lite');
      expect(appState.onlineModelName, equals('gemini-3.5-flash-lite'));
      expect(appState.activeModelDisplayName, equals('gemini3.5-flash-lite'));

      await appState.setUseOnlineLlm(false);
      expect(appState.useOnlineLlm, isFalse);
      expect(appState.activeModelDisplayName, equals('Gemma 4 E2B'));
    });
  });
}

