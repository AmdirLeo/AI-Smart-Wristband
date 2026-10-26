import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../models/models.dart';

/// 事件状态徽标（docs/API.md §5 状态）
class StatusChip extends StatelessWidget {
  final MsEventStatus status;
  const StatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final (color, bg) = switch (status) {
      MsEventStatus.pending => (AppTheme.warn, const Color(0xFFFDF2E2)),
      MsEventStatus.safe => (AppTheme.ok, const Color(0xFFE8F6EC)),
      MsEventStatus.helpRequested => (AppTheme.accent, const Color(0xFFFDEEE2)),
      MsEventStatus.simulatedNotification => (AppTheme.muted, const Color(0xFFEEF1F4)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Text(
        status.label,
        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 实时指标卡
class MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final IconData icon;
  final Color color;

  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            if (unit != null) ...[
              const SizedBox(width: 2),
              Text(unit!, style: TextStyle(fontSize: 12, color: AppTheme.muted)),
            ],
          ],
        ),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 12, color: AppTheme.muted)),
      ],
    );
  }
}

/// 加速度曲线（g 随时间），带 1.0g 基准线
class GSparkline extends StatelessWidget {
  final List<BandSample> samples;
  final double height;

  const GSparkline({super.key, required this.samples, this.height = 96});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _GPainter(samples)),
    );
  }
}

class _GPainter extends CustomPainter {
  final List<BandSample> samples;
  _GPainter(this.samples);

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;
    final values = samples.map((s) => s.g).toList();
    var minV = values.reduce((a, b) => a < b ? a : b) - 0.2;
    var maxV = values.reduce((a, b) => a > b ? a : b) + 0.2;
    if (maxV - minV < 0.5) {
      final mid = (maxV + minV) / 2;
      minV = mid - 0.25;
      maxV = mid + 0.25;
    }

    double yOf(double v) => size.height - (v - minV) / (maxV - minV) * size.height;

    // 1.0g 基准线
    final base = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, yOf(1.0)), Offset(size.width, yOf(1.0)), base);

    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = yOf(values[i]);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    final line = Paint()
      ..color = AppTheme.primary
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(_GPainter old) => !identical(old.samples, samples);
}
