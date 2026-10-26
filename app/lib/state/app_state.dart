import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/band_protocol.dart';
import '../ble/ble_service.dart';
import '../data/model_service_client.dart';
import '../models/models.dart';
import '../services/demo_engine.dart';
import '../services/tts_service.dart';

/// 全局状态：手环连接、实时数据、六轴缓冲、跌倒识别与事件确认。
/// 服务端为团队仓库的 model_service（契约见 docs/API.md）。
class AppState extends ChangeNotifier {
  // —— 配置（shared_preferences 持久化） ——
  String serverUrl = 'http://192.168.1.100:8000';
  String accessToken = '';

  // —— 模型服务 ——
  late final ModelServiceClient api;
  bool serverOk = false;
  ServiceInfo? info;

  // —— 手环 ——
  final BleService ble = BleService();
  BandConnState bandState = BandConnState.disconnected;
  String bandName = '';
  bool bandLost = false;

  // —— 实时状态帧（BLE / 演示模式共用展示） ——
  final List<BandSample> samples = [];
  static const int _maxSamples = 120;
  BandSample? get latest => samples.isEmpty ? null : samples.last;

  // —— 六轴缓冲（docs/API.md §3：整段 10–20 秒记录） ——
  /// 行格式 [timestamp_s, ax_g, ay_g, az_g, gx_dps, gy_dps, gz_dps]
  List<List<double>> rawWindow = [];
  String rawSource = '';

  double get windowSeconds {
    if (rawWindow.length < 2) return 0;
    return (rawWindow.last[0] - rawWindow.first[0]).abs();
  }

  /// 服务端要求记录时长 10–20 秒
  bool get windowReady => windowSeconds >= 9.5 && windowSeconds <= 20.5;

  // —— 识别与事件 ——
  bool predicting = false;
  PredictResult? lastResult;
  final List<Recognition> events = []; // 本会话识别产生的事件（服务端无历史查询接口）
  MsEvent? activeEvent; // 正在弹窗确认的事件
  Timer? _poll;

  // —— 一次性提示（UI 消费后 clearMessages） ——
  String? lastError;
  String? lastInfo;

  // —— 内部 ——
  final DemoEngine _demo = DemoEngine();
  final TtsService tts = TtsService();
  Timer? _hbTimer;
  StreamSubscription<BandFrame>? _frameSub;
  StreamSubscription<Map<String, dynamic>>? _demoSub;
  StreamSubscription<BandConnState>? _bandStateSub;
  bool _demoOn = false;

  AppState() {
    api = ModelServiceClient(baseUrl: serverUrl);
  }

  bool get demoMode => _demoOn;

  Future<void> init() async {
    await _loadPrefs();
    _frameSub = ble.frames.listen(_onFrame);
    _bandStateSub = ble.state.listen(_onBandState);
    await testServer();
    _startTimers();
  }

  // ———————————————— 配置 ————————————————
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    serverUrl = p.getString('serverUrl') ?? serverUrl;
    accessToken = p.getString('accessToken') ?? '';
    api.configure(url: serverUrl, token: accessToken);
  }

  Future<void> savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('serverUrl', serverUrl);
    await p.setString('accessToken', accessToken);
  }

  Future<void> applyServer(String url, String token) async {
    serverUrl = url.trim();
    accessToken = token.trim();
    api.configure(url: serverUrl, token: accessToken);
    await savePrefs();
    await testServer();
  }

  // ———————————————— 模型服务连接 ————————————————
  Future<void> testServer() async {
    serverOk = await api.ping();
    if (serverOk) {
      try {
        info = await api.info();
      } on ApiException catch (e) {
        info = null;
        lastError = '服务可达但 /api/info 失败(${e.statusCode})：${e.message}';
      }
    } else {
      info = null;
    }
    notifyListeners();
  }

  void _startTimers() {
    _hbTimer ??= Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!serverOk) await testServer();
    });
  }

  // ———————————————— 手环连接 ————————————————
  Future<void> connectBand() async {
    try {
      final ok = await ble.ensurePermissions();
      if (!ok) {
        lastError = '未授予蓝牙/定位权限，无法扫描手环';
        notifyListeners();
        return;
      }
      final results = await ble.scanForBands();
      if (results.isEmpty) {
        lastError = '未发现任何 BLE 设备，请确认手环已开机';
        notifyListeners();
        return;
      }
      if (demoMode) _setDemo(false);
      await ble.connect(results.first.device);
      bandName = ble.deviceName;
      bandLost = false;
      lastInfo = '已连接手环 $bandName';
    } catch (e) {
      lastError = '连接手环失败：$e';
    }
    notifyListeners();
  }

  Future<void> disconnectBand() async {
    await ble.disconnect();
    bandName = '';
    notifyListeners();
  }

  void _onBandState(BandConnState s) {
    if (s == BandConnState.disconnected && bandState == BandConnState.connected) {
      bandLost = true;
      lastInfo = '手环连接已断开，请检查手环电量';
    }
    bandState = s;
    notifyListeners();
  }

  // ———————————————— 演示模式 ————————————————
  void setDemoMode(bool v) => _setDemo(v);

  void _setDemo(bool v) {
    if (_demoOn == v) return;
    _demoOn = v;
    if (v) {
      if (ble.isConnected) ble.disconnect();
      _demo.start();
      _demoSub ??= _demo.frames.listen((m) =>
          _onFrame(BandFrame(m['t'] as String? ?? '', m)));
      bandName = '演示模式';
      bandState = BandConnState.connected;
      bandLost = false;
      lastInfo = '演示模式已开启：可生成六轴动作记录并识别';
    } else {
      _demo.stop();
      _demoSub?.cancel();
      _demoSub = null;
      bandName = ble.isConnected ? ble.deviceName : '';
      bandState = ble.currentState;
    }
    notifyListeners();
  }

  // ———————————————— 帧处理（BLE 与演示共用） ————————————————
  void _onFrame(BandFrame f) {
    switch (f.type) {
      case 'st':
        samples.add(BandSample.fromJson(f.raw));
        if (samples.length > _maxSamples) {
          samples.removeRange(0, samples.length - _maxSamples);
        }
      case 'raw':
        // 固件按 ≥14Hz 发送的原始六轴帧（列序同 docs/API.md）
        final row = f.arr('s');
        if (row.length == 7) {
          if (rawSource != '手环六轴') {
            rawWindow.clear();
            rawSource = '手环六轴';
          }
          rawWindow.add(row);
          // 只保留最近约 19 秒，保证识别窗口在 10–20 秒契约内
          while (rawWindow.length > 2 &&
              rawWindow.last[0] - rawWindow.first[0] > 19.5) {
            rawWindow.removeAt(0);
          }
        }
    }
    notifyListeners();
  }

  // ———————————————— 六轴窗口与识别 ————————————————
  /// 生成一段演示动作（跌倒/正常）并直接识别
  Future<void> demoRun({required bool fall}) async {
    rawWindow = _demo.generateWindow(fall: fall);
    rawSource = fall ? '演示·跌倒动作' : '演示·正常动作';
    notifyListeners();
    await runPredict();
  }

  /// 加载服务端公开样例（联调入口，见仓库 README「App 联调入口」）
  Future<void> loadSample(String id) async {
    if (!serverOk) {
      lastError = '云端未连接，无法加载公开样例';
      notifyListeners();
      return;
    }
    try {
      rawWindow = await api.sample(id);
      rawSource = '公开样例 $id';
      lastInfo = '已加载样例 $id（${rawWindow.length} 行），可运行识别';
    } on ApiException catch (e) {
      lastError = '样例加载失败(${e.statusCode})：${e.message}';
    }
    notifyListeners();
  }

  /// 上传当前六轴窗口做跌倒分类
  Future<void> runPredict() async {
    if (predicting) return;
    if (rawWindow.length < 10) {
      lastError = '还没有六轴数据：连接手环、打开演示模式或加载公开样例';
      notifyListeners();
      return;
    }
    if (!serverOk) {
      lastError = '云端未连接，无法识别';
      notifyListeners();
      return;
    }
    if (!windowReady) {
      lastError = '记录时长需 10–20 秒，当前 ${windowSeconds.toStringAsFixed(1)} 秒';
      notifyListeners();
      return;
    }
    predicting = true;
    notifyListeners();
    try {
      final r = await api.predict(rawWindow);
      lastResult = r;
      final ev = r.event;
      if (ev != null) {
        events.insert(0, Recognition(result: r, event: ev));
        activeEvent = ev;
        _startPoll(ev.id);
        await tts.speak('检测到疑似跌倒。您还好吗？如无碍请按我没事，需要帮助请按立即求助。');
      } else {
        lastInfo = '识别：正常（分数 ${r.score.toStringAsFixed(3)} < 阈值 ${r.threshold.toStringAsFixed(3)}）';
      }
    } on ApiException catch (e) {
      lastError = '识别失败(${e.statusCode})：${e.message}';
    } catch (e) {
      lastError = '识别失败：$e';
    } finally {
      predicting = false;
      notifyListeners();
    }
  }

  // ———————————————— 事件轮询与确认 ————————————————
  void _startPoll(String id) {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollTick(id));
  }

  Future<void> _pollTick(String id) async {
    try {
      final ev = await api.event(id);
      _upsertEvent(ev);
      if (activeEvent?.id == id) activeEvent = ev;
      if (ev.status.terminal) _poll?.cancel();
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        // 事件过期/被淘汰/服务重启：结束轮询
        _poll?.cancel();
        if (activeEvent?.id == id) activeEvent = null;
        lastError = '事件已过期或服务已重启，请重新识别';
      }
    } catch (_) {
      // 网络抖动，下一秒继续
    }
    notifyListeners();
  }

  /// 确认安全（safe）或求助（help）。409 时按文档重新查询更新页面。
  Future<void> confirmEvent(MsEvent ev, {required bool safe}) async {
    try {
      final updated = await api.confirm(ev.id, safe: safe);
      _upsertEvent(updated);
      if (activeEvent?.id == updated.id) activeEvent = updated;
      _poll?.cancel();
      lastInfo = safe ? '已确认安全' : '已请求帮助（模拟通知）';
      if (!safe) await tts.speak('求助已提交，将生成模拟通知。');
    } on ApiException catch (e) {
      if (e.statusCode == 409) {
        lastInfo = '事件已被处理或已超时，已刷新最新状态';
        _pollTick(ev.id);
      } else if (e.statusCode == 404) {
        _poll?.cancel();
        if (activeEvent?.id == ev.id) activeEvent = null;
        lastError = '事件已过期，请重新识别';
      } else {
        lastError = '确认失败(${e.statusCode})：${e.message}';
      }
    } catch (e) {
      lastError = '确认失败：$e';
    }
    notifyListeners();
  }

  /// SOS：当前契约没有独立 SOS 接口（docs/API.md §6），仅本地记录演示
  Future<void> sendSos() async {
    await tts.speak('求助信号已在本机记录。独立求助接口确定后，将自动通知家人。');
    lastInfo = 'SOS 已本地记录（独立 SOS 接口双方待定义，见 docs/API.md §6）';
    notifyListeners();
  }

  // ———————————————— 内部工具 ————————————————
  void _upsertEvent(MsEvent ev) {
    final i = events.indexWhere((r) => r.event.id == ev.id);
    if (i >= 0) {
      events[i].event = ev;
    }
  }

  void clearMessages() {
    lastError = null;
    lastInfo = null;
  }

  @override
  void dispose() {
    _poll?.cancel();
    _hbTimer?.cancel();
    _frameSub?.cancel();
    _bandStateSub?.cancel();
    _demoSub?.cancel();
    _demo.stop();
    ble.dispose();
    api.dispose();
    super.dispose();
  }
}
