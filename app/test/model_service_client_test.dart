import 'package:flutter_test/flutter_test.dart';
import 'package:yian_app/data/model_service_client.dart';
import 'package:yian_app/models/models.dart';

/// 集成测试：需要本机 model_service 在线（http://127.0.0.1:8000）。
/// 服务未启动时自动跳过，不影响离线 CI/本地 `flutter test`。
void main() {
  final api = ModelServiceClient(baseUrl: 'http://127.0.0.1:8000');
  var serviceUp = false;

  setUpAll(() async {
    serviceUp = await api.ping();
    if (!serviceUp) {
      // ignore: avoid_print
      print('跳过集成测试：model_service 未运行（启动方式见仓库根目录 README）');
    }
  });

  test('公开样例 → 识别 → 事件确认全流程', () async {
    if (!serviceUp) return;
    // 1) info
    final info = await api.info();
    expect(info.confirmSeconds, greaterThan(0));
    // 2) 跌倒样例 → 疑似跌倒 + 事件
    final rows = await api.sample('fall');
    expect(rows.length, greaterThan(100));
    final r = await api.predict(rows);
    expect(r.isSuspectedFall, isTrue);
    expect(r.event, isNotNull);
    // 3) 轮询事件
    final ev = await api.event(r.event!.id);
    expect(ev.id, r.event!.id);
    // 4) 确认安全 → 终态
    final confirmed = await api.confirm(ev.id, safe: true);
    expect(confirmed.status, MsEventStatus.safe);
    // 5) 重复相反确认 → 409
    await expectLater(
      api.confirm(ev.id, safe: false),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 409)),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('正常样例不产生事件；不存在的事件返回 404', () async {
    if (!serviceUp) return;
    final rows = await api.sample('normal');
    final r = await api.predict(rows);
    expect(r.isSuspectedFall, isFalse);
    expect(r.event, isNull);
    await expectLater(
      api.event('no-such-event'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 404)),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
