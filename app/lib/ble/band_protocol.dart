import 'dart:convert';

/// BLE 帧编解码（协议见 docs/BLE通信协议.md）：
/// 字节流 → 按 \n 切帧 → UTF-8 解码 → JSON。
/// 一帧可能被拆进多个 Notify 包（跨包粘包），解析器内部做字节级累积。
class BandFrame {
  final String type; // st / ev / ok
  final Map<String, dynamic> raw;

  BandFrame(this.type, this.raw);

  double numOf(String k) => (raw[k] as num?)?.toDouble() ?? 0;
  int intOf(String k) => (raw[k] as num?)?.toInt() ?? 0;

  /// raw 六轴帧的数据数组：[timestamp_s, ax_g, ay_g, az_g, gx_dps, gy_dps, gz_dps]
  List<double> arr(String k) =>
      ((raw[k] as List?) ?? const []).map((v) => (v as num).toDouble()).toList();
}

class BandProtocolParser {
  final List<int> _buf = [];
  static const int maxBuf = 4096;

  /// 喂入收到的原始字节，返回完整解析出的帧列表。
  List<BandFrame> push(List<int> bytes) {
    final frames = <BandFrame>[];
    _buf.addAll(bytes);
    while (true) {
      final i = _buf.indexOf(0x0A); // '\n'
      if (i < 0) break;
      final lineBytes = _buf.sublist(0, i);
      _buf.removeRange(0, i + 1);
      final f = _decode(utf8.decode(lineBytes, allowMalformed: true));
      if (f != null) frames.add(f);
    }
    if (_buf.length > maxBuf) _buf.clear(); // 防异常数据撑爆缓冲
    return frames;
  }

  BandFrame? _decode(String line) {
    final s = line.trim();
    if (s.isEmpty) return null;
    try {
      final j = jsonDecode(s);
      if (j is Map<String, dynamic> && j['t'] is String) {
        return BandFrame(j['t'] as String, j);
      }
    } on FormatException {
      // 半截/脏数据直接丢弃
    }
    return null;
  }

  // —— 手机 → 手环 帧 ——
  static List<int> frameMute() => utf8.encode('{"t":"mute"}\n');
  static List<int> frameAck(int seq) => utf8.encode('{"t":"ok","q":$seq}\n');
}
