// 数据模型：字段与团队仓库 docs/API.md（model_service 接口契约）一一对应。

/// BLE 状态帧（实时展示用）：合加速度/姿态/静止/电量
class BandSample {
  final double g;
  final double pitch;
  final double roll;
  final bool still;
  final int? battery;
  final DateTime ts;

  BandSample({
    required this.g,
    required this.pitch,
    required this.roll,
    required this.still,
    this.battery,
    DateTime? ts,
  }) : ts = ts ?? DateTime.now();

  factory BandSample.fromJson(Map<String, dynamic> j, {DateTime? ts}) {
    return BandSample(
      g: (j['g'] as num).toDouble(),
      pitch: (j['pitch'] as num?)?.toDouble() ?? 0,
      roll: (j['roll'] as num?)?.toDouble() ?? 0,
      still: j['still'] == true || j['still'] == 1,
      battery: (j['battery'] as num?)?.toInt(),
      ts: ts,
    );
  }
}

/// GET /api/info 返回
class ServiceInfo {
  final String name;
  final String mode;
  final List<String> columns;
  final int confirmSeconds;

  ServiceInfo({
    required this.name,
    required this.mode,
    required this.columns,
    required this.confirmSeconds,
  });

  factory ServiceInfo.fromJson(Map<String, dynamic> j) {
    return ServiceInfo(
      name: j['name'] as String? ?? '',
      mode: j['mode'] as String? ?? '',
      columns:
          ((j['columns'] as List?) ?? const []).map((c) => c.toString()).toList(),
      confirmSeconds: (j['confirm_seconds'] as num?)?.toInt() ?? 20,
    );
  }
}

/// /api/predict 返回的 label：只有 non_fall 和 suspected_fall
enum FallLabel { nonFall, suspectedFall }

extension FallLabelX on FallLabel {
  String get label => this == FallLabel.suspectedFall ? '疑似跌倒' : '正常';

  static FallLabel from(String s) =>
      s == 'suspected_fall' ? FallLabel.suspectedFall : FallLabel.nonFall;
}

/// POST /api/predict 返回（score 为未校准分数，不作为跌倒概率展示）
class PredictResult {
  final FallLabel label;
  final double score;
  final double threshold;
  final MsEvent? event;

  PredictResult({
    required this.label,
    required this.score,
    required this.threshold,
    this.event,
  });

  bool get isSuspectedFall => label == FallLabel.suspectedFall;

  factory PredictResult.fromJson(Map<String, dynamic> j) {
    return PredictResult(
      label: FallLabelX.from(j['label'] as String),
      score: (j['score'] as num).toDouble(),
      threshold: (j['threshold'] as num).toDouble(),
      event: j['event'] == null ? null : MsEvent.fromJson(j['event'] as Map<String, dynamic>),
    );
  }
}

/// 事件状态（docs/API.md §5）
enum MsEventStatus { pending, safe, helpRequested, simulatedNotification }

extension MsEventStatusX on MsEventStatus {
  String get label => switch (this) {
        MsEventStatus.pending => '待确认',
        MsEventStatus.safe => '已确认安全',
        MsEventStatus.helpRequested => '已请求帮助',
        MsEventStatus.simulatedNotification => '超时·模拟通知',
      };

  /// 终态（safe / help_requested / simulated_notification），终态后停止轮询
  bool get terminal => this != MsEventStatus.pending;

  static MsEventStatus from(String s) => switch (s) {
        'safe' => MsEventStatus.safe,
        'help_requested' => MsEventStatus.helpRequested,
        'simulated_notification' => MsEventStatus.simulatedNotification,
        _ => MsEventStatus.pending,
      };
}

/// 照护事件：推理响应的 event 字段与 GET /api/events/{id} 返回一致。
/// created_at / deadline 为 Unix 秒时间戳（App 端注意换算）。
class MsEvent {
  final String id;
  final MsEventStatus status;
  final double createdAt;
  final double deadline;
  final String? reason;

  MsEvent({
    required this.id,
    required this.status,
    required this.createdAt,
    required this.deadline,
    this.reason,
  });

  factory MsEvent.fromJson(Map<String, dynamic> j) {
    return MsEvent(
      id: j['id'] as String,
      status: MsEventStatusX.from(j['status'] as String),
      createdAt: (j['created_at'] as num).toDouble(),
      deadline: (j['deadline'] as num).toDouble(),
      reason: j['reason'] as String?,
    );
  }

  /// 距确认截止的剩余秒数（本地时钟近似，最终以服务端为准）
  int get remainingSeconds {
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    return (deadline - now).ceil().clamp(0, 999);
  }

  String get shortId => id.length <= 8 ? id : id.substring(0, 8);

  MsEvent copyWith({MsEventStatus? status, String? reason}) {
    return MsEvent(
      id: id,
      status: status ?? this.status,
      createdAt: createdAt,
      deadline: deadline,
      reason: reason ?? this.reason,
    );
  }
}

/// 一次识别的完整记录（结果 + 事件），用于事件列表展示
class Recognition {
  final PredictResult result;
  final DateTime at;
  MsEvent event;

  Recognition({required this.result, required this.event, DateTime? at})
      : at = at ?? DateTime.now();

  String get title => result.isSuspectedFall ? '疑似跌倒事件' : '正常记录';
}
