import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_state.dart';

/// 跌倒确认弹窗（对齐 docs/API.md §5）：
/// - 倒计时以服务端 deadline 为准（confirm_seconds 从 /api/info 获取，当前 20 秒）；
/// - 状态由 AppState 每秒轮询刷新；
/// - 「我没事」→ confirm safe；「立即求助」→ confirm help；
/// - 超时 → 服务端置为 simulated_notification（模拟通知）；
/// - 409 冲突由 AppState 重新查询，本弹窗只按最新状态渲染。
class FallConfirmDialog extends StatefulWidget {
  final MsEvent event;
  const FallConfirmDialog({super.key, required this.event});

  @override
  State<FallConfirmDialog> createState() => _FallConfirmDialogState();
}

class _FallConfirmDialogState extends State<FallConfirmDialog> {
  Timer? _ticker;
  int _left = 20;

  @override
  void initState() {
    super.initState();
    _left = widget.event.remainingSeconds;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        context.read<AppState>().tts.speak('检测到疑似跌倒。您还好吗？如无碍请按我没事，需要帮助请按立即求助。');
      }
    });
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final ev = context.read<AppState>().activeEvent ?? widget.event;
      setState(() => _left = ev.remainingSeconds);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ev = state.activeEvent ?? widget.event;
    final pending = ev.status == MsEventStatus.pending;
    final total = state.info?.confirmSeconds ?? 20;

    return PopScope(
      canPop: !pending, // 待确认期间不允许点外部/返回关闭
      child: Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: CircularProgressIndicator(
                      value: pending ? (_left / total).clamp(0.0, 1.0) : 1,
                      strokeWidth: 7,
                      backgroundColor: Colors.grey.shade200,
                      color: pending ? AppTheme.danger : AppTheme.warn,
                      strokeCap: StrokeCap.round,
                    ),
                  ),
                  Text(pending ? '$_left' : '!',
                      style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800)),
                ],
              ),
              const SizedBox(height: 18),
              Text(_title(ev), style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text(_subtitle(ev),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: AppTheme.muted, height: 1.5)),
              const SizedBox(height: 22),
              if (pending)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          foregroundColor: AppTheme.ok,
                          side: const BorderSide(color: AppTheme.ok, width: 1.6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => _confirm(context, safe: true),
                        child: const Text('我没事',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          backgroundColor: AppTheme.danger,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () => _confirm(context, safe: false),
                        child: const Text('立即求助',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  ],
                )
              else
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('知道了', style: TextStyle(fontSize: 16)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirm(BuildContext context, {required bool safe}) async {
    final state = context.read<AppState>();
    await state.confirmEvent(state.activeEvent ?? widget.event, safe: safe);
  }

  String _title(MsEvent ev) => switch (ev.status) {
        MsEventStatus.pending => '检测到疑似跌倒',
        MsEventStatus.safe => '已确认安全',
        MsEventStatus.helpRequested => '已请求帮助',
        MsEventStatus.simulatedNotification => '确认超时',
      };

  String _subtitle(MsEvent ev) => switch (ev.status) {
        MsEventStatus.pending =>
          '您还好吗？\n如无碍请按「我没事」，需要帮助请按「立即求助」',
        MsEventStatus.safe => '已确认安全，事件已记录（reason: user_confirmation）',
        MsEventStatus.helpRequested => '已生成模拟通知（演示环境不会真实联系家属）',
        MsEventStatus.simulatedNotification => '超过确认时限，已生成模拟通知\n（演示环境不会真实联系家属）',
      };
}
