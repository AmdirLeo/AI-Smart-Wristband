import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// 照护事件页：展示本会话识别产生的事件并支持确认操作。
/// 说明：model_service 无历史查询接口，事件只存于服务内存（1 小时 TTL），
/// 因此这里仅列出本次 App 运行期间识别到的事件。
class EventsTab extends StatelessWidget {
  const EventsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final items = state.events;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text('仅显示本次运行识别的事件（服务端事件保存在内存，1 小时内有效）',
              style: TextStyle(fontSize: 12, color: AppTheme.muted)),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.receipt_long_outlined, size: 44, color: Colors.grey.shade300),
                      const SizedBox(height: 10),
                      const Text('暂无事件',
                          style: TextStyle(color: AppTheme.muted)),
                      const SizedBox(height: 6),
                      const Text('到「实时守护」页运行跌倒识别',
                          style: TextStyle(color: AppTheme.muted, fontSize: 12)),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _EventCard(rec: items[i]),
                ),
        ),
      ],
    );
  }
}

class _EventCard extends StatelessWidget {
  final Recognition rec;
  const _EventCard({required this.rec});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ev = rec.event;
    final danger = rec.result.isSuspectedFall;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(danger ? Icons.personal_injury : Icons.directions_walk,
                    size: 18, color: danger ? AppTheme.danger : AppTheme.ok),
                const SizedBox(width: 6),
                Text(rec.title,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: danger ? AppTheme.danger : AppTheme.ok)),
                const SizedBox(width: 8),
                StatusChip(ev.status),
                const Spacer(),
                Text(DateFormat('MM-dd HH:mm:ss').format(rec.at),
                    style: const TextStyle(fontSize: 12, color: AppTheme.muted)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '分数 ${rec.result.score.toStringAsFixed(3)} / 阈值 ${rec.result.threshold.toStringAsFixed(3)}'
              '${ev.reason == null ? '' : ' · ${_reasonText(ev.reason!)}'}'
              ' · 事件 ${ev.shortId}',
              style: const TextStyle(fontSize: 12, color: AppTheme.muted),
            ),
            const SizedBox(height: 4),
            Text(_hint(ev.status), style: const TextStyle(fontSize: 12, color: AppTheme.muted)),
            if (ev.status == MsEventStatus.pending) ...[
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.ok,
                        side: const BorderSide(color: AppTheme.ok)),
                    onPressed: () =>
                        state.confirmEvent(ev, safe: true),
                    child: const Text('我没事', style: TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
                    onPressed: () =>
                        state.confirmEvent(ev, safe: false),
                    child: const Text('需要帮助', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  String _reasonText(String reason) => switch (reason) {
        'user_confirmation' => '用户确认',
        'confirmation_timeout' => '确认超时',
        _ => reason,
      };

  String _hint(MsEventStatus s) => switch (s) {
        MsEventStatus.pending => '等待用户确认（每秒轮询服务端状态）',
        MsEventStatus.safe => '用户已确认安全（App 文案：已确认安全）',
        MsEventStatus.helpRequested => '已生成模拟通知（演示环境不会真实联系家属）',
        MsEventStatus.simulatedNotification => '已超时，已生成模拟通知（演示环境不会真实联系家属）',
      };
}
