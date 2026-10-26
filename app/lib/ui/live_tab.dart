import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// 实时页：手环连接、实时状态、六轴窗口、跌倒识别入口、长按 SOS。
class LiveTab extends StatelessWidget {
  const LiveTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _ConnectionCard(state: state),
        const SizedBox(height: 12),
        const _DemoCard(),
        const SizedBox(height: 12),
        _LiveCard(state: state),
        const SizedBox(height: 12),
        const _PredictCard(),
        const SizedBox(height: 12),
        const _SosButton(),
        const SizedBox(height: 30),
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  final AppState state;
  const _ConnectionCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final (text, color, icon) = switch (state.bandState) {
      BandConnState.connected => ('已连接 · ${state.bandName}', AppTheme.ok, Icons.bluetooth_connected),
      BandConnState.connecting => ('连接中…', AppTheme.warn, Icons.bluetooth_searching),
      BandConnState.scanning => ('正在扫描手环…', AppTheme.warn, Icons.bluetooth_searching),
      BandConnState.disconnected => ('手环未连接', AppTheme.muted, Icons.bluetooth_disabled),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('手环：$text',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                if (state.bandState == BandConnState.connected)
                  OutlinedButton(
                    onPressed: state.disconnectBand,
                    child: const Text('断开'),
                  )
                else
                  FilledButton(
                    onPressed: state.bandState == BandConnState.scanning ||
                            state.bandState == BandConnState.connecting
                        ? null
                        : state.connectBand,
                    child: const Text('扫描并连接'),
                  ),
              ],
            ),
            if (state.bandLost) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFFDF2E2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(children: [
                  Icon(Icons.warning_amber_rounded, color: AppTheme.warn, size: 18),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text('检测到手环断连，请检查手环电量与佩戴。',
                        style: TextStyle(fontSize: 13, color: Color(0xFF92400E))),
                  ),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DemoCard extends StatelessWidget {
  const _DemoCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Card(
      child: SwitchListTile(
        title: const Text('演示模式',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        subtitle: const Text('没有手环时，在 App 内生成六轴动作记录（答辩演示用）',
            style: TextStyle(fontSize: 12)),
        value: state.demoMode,
        activeThumbColor: AppTheme.primary,
        onChanged: (v) => state.setDemoMode(v),
        secondary: const Icon(Icons.science_outlined),
      ),
    );
  }
}

class _LiveCard extends StatelessWidget {
  final AppState state;
  const _LiveCard({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state.latest;
    final battery = s?.battery;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.monitor_heart_outlined, size: 18, color: AppTheme.primary),
              SizedBox(width: 6),
              Text('实时状态',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 12),
            if (s == null)
              SizedBox(
                height: 120,
                child: Center(
                  child: Text(
                    state.demoMode ? '演示数据生成中…' : '等待手环数据…\n（连接手环或打开演示模式）',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.muted, fontSize: 13, height: 1.6),
                  ),
                ),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                      child: MetricTile(
                          label: '合加速度',
                          value: s.g.toStringAsFixed(2),
                          unit: 'g',
                          icon: Icons.speed,
                          color: AppTheme.primary)),
                  Expanded(
                      child: MetricTile(
                          label: '俯仰角',
                          value: s.pitch.toStringAsFixed(0),
                          unit: '°',
                          icon: Icons.screen_rotation_alt,
                          color: AppTheme.primaryDeep)),
                  Expanded(
                      child: MetricTile(
                          label: '状态',
                          value: s.still ? '静止' : '活动',
                          icon: s.still ? Icons.airline_seat_individual_suite : Icons.directions_walk,
                          color: s.still ? AppTheme.warn : AppTheme.ok)),
                ],
              ),
              const SizedBox(height: 10),
              GSparkline(samples: state.samples),
              if (battery != null) ...[
                const SizedBox(height: 10),
                Row(children: [
                  Icon(Icons.battery_alert,
                      size: 16,
                      color: battery < 20 ? AppTheme.danger : AppTheme.muted),
                  const SizedBox(width: 4),
                  Text('手环电量 $battery%',
                      style: TextStyle(
                          fontSize: 12,
                          color: battery < 20 ? AppTheme.danger : AppTheme.muted)),
                ]),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// 六轴窗口 + 跌倒识别操作（联调入口对齐仓库 README「App 联调入口」）
class _PredictCard extends StatelessWidget {
  const _PredictCard();

  static const _sampleIds = ['normal', 'fall', 'false_positive', 'false_negative'];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final result = state.lastResult;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.psychology_alt_outlined, size: 18, color: AppTheme.primary),
              SizedBox(width: 6),
              Text('跌倒识别',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                state.rawWindow.isEmpty
                    ? '六轴窗口：空 —— 加载公开样例、生成演示动作或连接发送 raw 帧的手环'
                    : '六轴窗口：${state.rawSource} · ${state.windowSeconds.toStringAsFixed(1)} 秒 / ${state.rawWindow.length} 行'
                        '${state.windowReady ? '' : '（需 10–20 秒）'}',
                style: TextStyle(
                    fontSize: 12,
                    color: state.windowReady ? AppTheme.primaryDeep : AppTheme.muted),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final id in _sampleIds)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        visualDensity: VisualDensity.compact),
                    onPressed:
                        state.serverOk ? () => state.loadSample(id) : null,
                    child: Text('样例 $id', style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: state.demoMode ? () => state.demoRun(fall: false) : null,
                  icon: const Icon(Icons.directions_walk, size: 18),
                  label: const Text('演示·正常'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: state.demoMode ? () => state.demoRun(fall: true) : null,
                  icon: const Icon(Icons.personal_injury, size: 18),
                  label: const Text('演示·跌倒'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: state.serverOk && state.windowReady && !state.predicting
                    ? state.runPredict
                    : null,
                icon: state.predicting
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.play_arrow, size: 20),
                label: Text(state.predicting ? '识别中…' : '运行跌倒识别',
                    style: const TextStyle(fontSize: 15)),
              ),
            ),
            if (result != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (result.isSuspectedFall ? AppTheme.danger : AppTheme.ok)
                      .withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '上次识别：${result.label.label} · 分数 ${result.score.toStringAsFixed(3)}'
                  '（阈值 ${result.threshold.toStringAsFixed(3)}）\n'
                  '分数为未校准分类分数，不代表跌倒概率（见 docs/API.md §4）',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: result.isSuspectedFall ? AppTheme.danger : AppTheme.ok),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 长按 1.5 秒触发 SOS（当前契约无独立 SOS 接口，仅本地演示）
class _SosButton extends StatefulWidget {
  const _SosButton();

  @override
  State<_SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<_SosButton> {
  static const _hold = Duration(milliseconds: 1500);
  Timer? _timer;
  double _progress = 0;

  void _start() {
    _timer?.cancel();
    setState(() => _progress = 0.02);
    final begin = DateTime.now();
    _timer = Timer.periodic(const Duration(milliseconds: 50), (t) {
      final p = DateTime.now().difference(begin).inMilliseconds / _hold.inMilliseconds;
      if (p >= 1) {
        t.cancel();
        _timer = null;
        setState(() => _progress = 0);
        context.read<AppState>().sendSos();
      } else {
        setState(() => _progress = p);
      }
    });
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    if (mounted) setState(() => _progress = 0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => _start(),
      onLongPressEnd: (_) => _cancel(),
      onLongPressCancel: _cancel,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Container(
              height: 88,
              color: AppTheme.danger,
              alignment: Alignment.center,
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.emergency, color: Colors.white, size: 30),
                      SizedBox(width: 10),
                      Text('长按 SOS 求助',
                          style: TextStyle(
                              color: Colors.white, fontSize: 21,
                              fontWeight: FontWeight.w800, letterSpacing: 2)),
                    ],
                  ),
                  SizedBox(height: 4),
                  Text('独立 SOS 接口确定前仅本机记录',
                      style: TextStyle(color: Colors.white70, fontSize: 11)),
                ],
              ),
            ),
            if (_progress > 0)
              LinearProgressIndicator(
                value: _progress,
                minHeight: 5,
                backgroundColor: Colors.white24,
                color: Colors.white,
              ),
          ],
        ),
      ),
    );
  }
}
