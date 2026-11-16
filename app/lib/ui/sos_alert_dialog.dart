import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../state/app_state.dart';

/// 面向监护人的告警展示；关闭只表示已读，不取消老人的求助。
class SosAlertDialog extends StatelessWidget {
  final MsEvent event;
  const SosAlertDialog({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cancelled = event.status == MsEventStatus.cancelled;
    return AlertDialog(
      icon: Icon(
        cancelled ? Icons.info_outline : Icons.emergency,
        color: cancelled ? AppTheme.warn : AppTheme.danger,
        size: 48,
      ),
      title: Text(cancelled ? '老人已取消 SOS' : '老人紧急求助'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            cancelled
                ? '老人按下了手表取消键。原告警记录已保留，请核实老人情况。'
                : '老人已按下手表 SOS，请立即查看并联系老人。',
          ),
          if (state.sosNeedsSync(event.id)) ...[
            const SizedBox(height: 12),
            const Text('本机已收到，云端尚未确认同步。'),
            TextButton(
              onPressed: state.sosSyncing(event.id)
                  ? null
                  : () => state.retrySosSync(event.id),
              child: Text(state.sosSyncing(event.id) ? '正在同步…' : '重试同步'),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            state.tts.stop();
            if (state.activeEvent?.id == event.id) state.activeEvent = null;
            Navigator.of(context).pop();
          },
          child: const Text('我已知晓'),
        ),
      ],
    );
  }
}
