import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ble/ble_service.dart';
import '../core/theme.dart';
import '../state/app_state.dart';

/// 设置：模型服务地址、访问口令、连接测试、关于。
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  late final _server = TextEditingController(text: '');
  late final _token = TextEditingController(text: '');
  bool _inited = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!_inited) {
      _inited = true;
      _server.text = state.serverUrl;
      _token.text = state.accessToken;
    }

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _Card(
          title: '模型服务',
          icon: Icons.cloud_outlined,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _server,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: '服务地址',
                  hintText: 'http://192.168.1.100:8000（模拟器用 http://10.0.2.2:8000）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _token,
                decoration: const InputDecoration(
                  labelText: '访问口令（可选，DEMO_ACCESS_TOKEN）',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 10),
              Row(children: [
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 16)),
                  onPressed: () => state.applyServer(_server.text, _token.text),
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('保存并测试'),
                ),
                const SizedBox(width: 12),
                Icon(Icons.circle, size: 10,
                    color: state.serverOk ? AppTheme.ok : AppTheme.danger),
                const SizedBox(width: 6),
                Text(state.serverOk ? '已连接' : '未连接',
                    style: TextStyle(
                        fontSize: 13,
                        color: state.serverOk ? AppTheme.ok : AppTheme.muted)),
              ]),
              if (state.info != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${state.info!.name} · 模式 ${state.info!.mode} · 确认时限 ${state.info!.confirmSeconds} 秒',
                  style: const TextStyle(fontSize: 12, color: AppTheme.muted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Card(
          title: '手环',
          icon: Icons.watch,
          child: Text(
            state.bandState == BandConnState.connected
                ? '已连接：${state.bandName}'
                : '未连接。到「实时守护」页扫描连接；识别所需的六轴 raw 帧协议见项目 docs/BLE通信协议.md。',
            style: const TextStyle(fontSize: 13, height: 1.6, color: AppTheme.muted),
          ),
        ),
        const SizedBox(height: 12),
        const _Card(
          title: '关于',
          icon: Icons.info_outline,
          child: Text(
            '颐安云护 App v0.2.0（对接 model_service 整段推理演示）\n\n'
            '· 接口契约：仓库 docs/API.md（先公开样例联调，再接 BLE 数据）\n'
            '· 识别输入：10–20 秒六轴记录（20/50Hz，单位秒、g、°/s）\n'
            '· 事件流程：疑似跌倒 → deadline 内确认 safe / help，超时为模拟通知\n'
            '· 注意：当前分数非医学概率，通知为模拟，无真实家属推送\n\n'
            '服务启动方式见仓库根目录 README。',
            style: TextStyle(fontSize: 13, height: 1.7, color: AppTheme.muted),
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }

  @override
  void dispose() {
    _server.dispose();
    _token.dispose();
    super.dispose();
  }
}

class _Card extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const _Card({required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 18, color: AppTheme.primary),
              const SizedBox(width: 6),
              Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}
