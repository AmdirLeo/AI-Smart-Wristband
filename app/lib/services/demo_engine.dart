import 'dart:async';
import 'dart:math';

/// 演示模式引擎：
/// 1) 周期产生与 BLE 协议同构的状态帧（实时页展示）；
/// 2) 生成与 docs/API.md 推理输入同构的整段六轴记录（15 秒 @ 20 Hz），
///    用于没有手环时走通「识别 → 事件 → 确认」全流程。
class DemoEngine {
  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  Timer? _timer;
  final _rng = Random();

  double _g = 1.02;
  double _p = 3;
  double _r = -4;
  int _bat = 87;
  int _seq = 0;

  /// 与 BLE 收到的状态帧同构：{"t":"st",...}
  Stream<Map<String, dynamic>> get frames => _ctrl.stream;
  bool get running => _timer != null;

  void start() {
    stop();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      _tick();
      _ctrl.add(_stateFrame());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _tick() {
    _g = max(0.8, min(1.6, _g + _rng.nextDouble() * 0.24 - 0.12));
    _p = max(-60, min(60, _p + _rng.nextDouble() * 16 - 8));
    _r = max(-60, min(60, _r + _rng.nextDouble() * 16 - 8));
    _seq += 1;
    if (_seq % 30 == 0 && _bat > 5) _bat -= 1;
  }

  Map<String, dynamic> _stateFrame() {
    _seq += 1;
    return {
      't': 'st',
      'g': double.parse(_g.toStringAsFixed(2)),
      'p': double.parse(_p.toStringAsFixed(1)),
      'r': double.parse(_r.toStringAsFixed(1)),
      's': _rng.nextDouble() < 0.15 ? 1 : 0,
      'b': _bat,
      'q': _seq,
    };
  }

  /// 生成 15 秒 @20Hz 的六轴记录，列序与 docs/API.md 一致：
  /// [timestamp_s, ax_g, ay_g, az_g, gx_dps, gy_dps, gz_dps]。
  /// fall=true 时在后三分之一植入「冲击 + 持续静止」的跌倒形态。
  List<List<double>> generateWindow({required bool fall}) {
    const hz = 20;
    const seconds = 15;
    final rows = <List<double>>[];
    for (var i = 0; i < hz * seconds; i++) {
      final t = i / hz;
      final phase = i / (hz * seconds);
      double ax, ay, az, gx, gy, gz;
      if (fall && phase >= 0.68) {
        // 跌倒后持续静止：仅剩重力，角速度归零
        ax = _n(0.01);
        ay = _n(0.01);
        az = 1.0 + _n(0.008);
        gx = _n(0.4);
        gy = _n(0.4);
        gz = _n(0.4);
        if (phase < 0.72) {
          // 冲击瞬间：加速度冲高 + 角速度大幅翻转
          az = 2.9 + _rng.nextDouble() * 0.6;
          ax = _n(0.8);
          gy = 90 + _rng.nextDouble() * 60;
          gx = -60 - _rng.nextDouble() * 60;
        }
      } else {
        // 日常步行：重力附近摆动 + 轻微角速度
        az = 1.0 + 0.08 * sin(2 * pi * 1.6 * t) + _n(0.02);
        ax = 0.06 * sin(2 * pi * 0.8 * t) + _n(0.02);
        ay = 0.05 * cos(2 * pi * 0.8 * t) + _n(0.02);
        gx = 4 * sin(2 * pi * 1.6 * t) + _n(1.5);
        gy = 3 * cos(2 * pi * 1.6 * t) + _n(1.5);
        gz = _n(2);
      }
      rows.add([
        double.parse(t.toStringAsFixed(3)),
        double.parse(ax.toStringAsFixed(4)),
        double.parse(ay.toStringAsFixed(4)),
        double.parse(az.toStringAsFixed(4)),
        double.parse(gx.toStringAsFixed(3)),
        double.parse(gy.toStringAsFixed(3)),
        double.parse(gz.toStringAsFixed(3)),
      ]);
    }
    return rows;
  }

  double _n(double scale) => (_rng.nextDouble() * 2 - 1) * scale;
}
