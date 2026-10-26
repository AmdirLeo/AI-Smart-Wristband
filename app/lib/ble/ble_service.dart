import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'band_protocol.dart';

/// 手环连接状态
enum BandConnState { disconnected, scanning, connecting, connected }

/// BLE 服务：扫描名为 YianBand* 的手环，连接 Nordic UART Service 收发帧。
/// 所有 flutter_blue_plus 细节都封装在这里，App 其余部分只认 frames 流和状态。
class BleService {
  static const advPrefix = 'yianband';
  static const svcUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const txUuid = '6e400003-b5a3-f393-e0a9-e50e24dcca9e'; // 手环→手机 Notify
  static const rxUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e'; // 手机→手环 Write

  final _frameCtrl = StreamController<BandFrame>.broadcast();
  final _stateCtrl = StreamController<BandConnState>.broadcast();
  final _parser = BandProtocolParser();

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  StreamSubscription? _notifySub, _connSub;
  BandConnState _state = BandConnState.disconnected;
  String deviceName = '';
  bool wantConnected = false; // 断线后是否应自动重连

  Stream<BandFrame> get frames => _frameCtrl.stream;
  Stream<BandConnState> get state => _stateCtrl.stream;
  BandConnState get currentState => _state;
  bool get isConnected => _state == BandConnState.connected;

  void _setState(BandConnState s) {
    _state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  /// 请求蓝牙/定位运行时权限（Android 12+ 需要 SCAN/CONNECT）
  Future<bool> ensurePermissions() async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    final perms = [
      Permission.locationWhenInUse,
      if (Platform.isAndroid) Permission.bluetoothScan,
      if (Platform.isAndroid) Permission.bluetoothConnect,
    ];
    final results = await perms.request();
    return results.values.every((s) => s.isGranted || s.isLimited);
  }

  /// 扫描 6 秒，返回广播名以 YianBand 开头的手环（按信号强度排序）。
  /// 找不到时返回所有有名设备，供 UI 提示/手动排查。
  Future<List<ScanResult>> scanForBands({Duration timeout = const Duration(seconds: 6)}) async {
    await FlutterBluePlus.stopScan();
    final found = <String, ScanResult>{};
    final sub = FlutterBluePlus.scanResults.listen((rs) {
      for (final r in rs) {
        final name = r.advertisementData.advName.trim();
        if (name.isNotEmpty) found[r.device.remoteId.str] = r;
      }
    });
    _setState(BandConnState.scanning);
    try {
      await FlutterBluePlus.startScan(timeout: timeout, androidUsesFineLocation: false);
      await FlutterBluePlus.isScanning.where((v) => !v).first;
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
    final all = found.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    final bands = all
        .where((r) => r.advertisementData.advName.toLowerCase().startsWith(advPrefix))
        .toList();
    if (bands.isNotEmpty) _setState(BandConnState.disconnected);
    return bands.isEmpty ? all : bands;
  }

  Future<void> connect(BluetoothDevice device) async {
    await disconnect();
    wantConnected = true;
    _device = device;
    deviceName = device.platformName.isNotEmpty ? device.platformName : 'YianBand';
    _setState(BandConnState.connecting);
    try {
      await device.connect(autoConnect: false, timeout: const Duration(seconds: 10));
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(185);
        } catch (_) {/* 协商失败不影响通信，只是帧要拆包 */}
      }
      final services = await device.discoverServices();
      BluetoothService? nus;
      for (final s in services) {
        if (s.uuid.str.toLowerCase() == svcUuid) nus = s;
      }
      if (nus == null) throw Exception('未找到 Nordic UART 服务（固件未按协议广播？）');
      for (final c in nus.characteristics) {
        final u = c.uuid.str.toLowerCase();
        if (u == txUuid) {
          await c.setNotifyValue(true);
          _notifySub?.cancel();
          _notifySub = c.onValueReceived.listen((v) {
            for (final f in _parser.push(v)) {
              if (!_frameCtrl.isClosed) _frameCtrl.add(f);
            }
          });
          device.cancelWhenDisconnected(_notifySub!);
        }
        if (u == rxUuid) _rx = c;
      }
      _connSub?.cancel();
      _connSub = device.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && wantConnected) {
          _setState(BandConnState.disconnected);
        }
      });
      _setState(BandConnState.connected);
    } catch (e) {
      wantConnected = false;
      _setState(BandConnState.disconnected);
      rethrow;
    }
  }

  Future<void> disconnect() async {
    wantConnected = false;
    await _notifySub?.cancel();
    await _connSub?.cancel();
    _notifySub = null;
    _connSub = null;
    _rx = null;
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
    FlutterBluePlus.stopScan();
    _setState(BandConnState.disconnected);
  }

  /// 发帧给手环（静音/回执等）
  Future<void> send(List<int> bytes) async {
    final rx = _rx;
    if (rx == null || !isConnected) return;
    try {
      await rx.write(bytes, withoutResponse: true);
    } catch (_) {}
  }

  void dispose() {
    _notifySub?.cancel();
    _connSub?.cancel();
    _frameCtrl.close();
    _stateCtrl.close();
  }
}
