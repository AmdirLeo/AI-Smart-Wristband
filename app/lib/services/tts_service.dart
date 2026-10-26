import 'package:flutter_tts/flutter_tts.dart';

/// 中文语音询问（“您还好吗”）。原型阶段由手机播报；
/// 正式版可由手环端扬声器（MAX98357A）播报，接口不变。
class TtsService {
  final _tts = FlutterTts();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.setSpeechRate(0.45);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      _ready = true;
    } catch (_) {
      _ready = false; // 无 TTS 引擎的设备上静默降级
    }
  }

  Future<void> speak(String text) async {
    await init();
    if (!_ready) return;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> stop() async {
    if (!_ready) return;
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
