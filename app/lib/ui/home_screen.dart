import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'events_tab.dart';
import 'fall_confirm_dialog.dart';
import 'live_tab.dart';
import 'settings_tab.dart';

/// 主框架：三个 Tab + 跌倒确认弹窗调度 + 全局消息提示。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  bool _fallDialogOpen = false;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    _handleMessages(state);
    _maybeShowFallDialog(state);

    return Scaffold(
      appBar: AppBar(
        title: const Text('颐安云护'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Row(children: [
                Icon(Icons.circle, size: 9,
                    color: state.serverOk ? AppTheme.ok : AppTheme.danger),
                const SizedBox(width: 5),
                Text(state.serverOk ? '服务已连接' : '服务离线',
                    style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _tab,
        children: const [
          LiveTab(),
          EventsTab(),
          SettingsTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        height: 68,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.watch_outlined),
              selectedIcon: Icon(Icons.watch),
              label: '实时守护'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: state.events.any((r) => !r.event.status.terminal),
              label: const Text('!'),
              child: const Icon(Icons.notifications_outlined),
            ),
            selectedIcon: const Icon(Icons.notifications),
            label: '照护事件',
          ),
          const NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: '设置'),
        ],
      ),
    );
  }

  /// 消费 AppState 的一次性消息 → SnackBar
  void _handleMessages(AppState state) {
    if (state.lastError == null && state.lastInfo == null) return;
    final isErr = state.lastError != null;
    final msg = state.lastError ?? state.lastInfo!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 3),
          backgroundColor: isErr ? AppTheme.danger : AppTheme.primary,
        ));
      state.clearMessages();
    });
  }

  /// 有待确认的跌倒事件 → 弹确认窗（服务端 deadline 为准）
  void _maybeShowFallDialog(AppState state) {
    final ev = state.activeEvent;
    if (ev == null || _fallDialogOpen) return;
    _fallDialogOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => FallConfirmDialog(event: ev),
      );
      _fallDialogOpen = false;
      if (mounted) setState(() {});
    });
  }
}
