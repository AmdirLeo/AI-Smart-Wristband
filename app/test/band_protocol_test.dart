import 'package:flutter_test/flutter_test.dart';
import 'package:yian_app/ble/band_protocol.dart';
import 'package:yian_app/models/models.dart';

void main() {
  group('BandProtocolParser', () {
    test('一帧被拆进两个 BLE 包时能正确拼帧', () {
      final p = BandProtocolParser();
      final raw =
          '{"t":"st","g":1.02,"p":3.2,"r":-4.0,"s":0,"b":87,"q":1}\n'.codeUnits;
      expect(p.push(raw.sublist(0, 10)), isEmpty);
      final frames = p.push(raw.sublist(10));
      expect(frames, hasLength(1));
      expect(frames.first.type, 'st');
      expect(frames.first.numOf('g'), 1.02);
      expect(frames.first.intOf('q'), 1);
    });

    test('多条帧混合脏数据时跳过无法解析的行', () {
      final p = BandProtocolParser();
      final raw =
          'garbage line\n{"t":"ev","k":"fall","i":3.2,"w":12.0,"c":0.88,"q":2}\n'
                  'broken\n{"t":"ok","q":3}\n'
              .codeUnits;
      final frames = p.push(raw);
      expect(frames.map((f) => f.type), ['ev', 'ok']);
      expect(frames.first.raw['k'], 'fall');
      expect(frames.first.numOf('c'), closeTo(0.88, 1e-9));
    });

    test('raw 六轴帧解析', () {
      final p = BandProtocolParser();
      final raw =
          '{"t":"raw","s":[0.000,0.01,0.02,1.00,1.5,-2.0,0.3]}\n'.codeUnits;
      final frames = p.push(raw);
      expect(frames, hasLength(1));
      expect(frames.first.type, 'raw');
      expect(frames.first.arr('s'), hasLength(7));
      expect(frames.first.arr('s')[3], 1.00);
    });

    test('下行帧编码', () {
      expect(BandProtocolParser.frameMute(), '{"t":"mute"}\n'.codeUnits);
      expect(BandProtocolParser.frameAck(7), '{"t":"ok","q":7}\n'.codeUnits);
    });
  });

  group('models（docs/API.md 示例响应）', () {
    test('PredictResult + MsEvent 解析', () {
      final j = {
        'label': 'suspected_fall',
        'score': 0.9805510706095325,
        'threshold': 0.2009596081649438,
        'note': 'Uncalibrated whole-trial score; not a real-time alarm decision.',
        'mode': 'whole_trial_demo',
        'event': {
          'id': '3f54285b-e464-40f2-aaca-30e1bffb0416',
          'status': 'pending',
          'created_at': 1793000000.0,
          'deadline': 1793000020.0,
          'reason': null,
          'notification_mode': 'simulation_only',
        },
      };
      final r = PredictResult.fromJson(j);
      expect(r.isSuspectedFall, isTrue);
      expect(r.score, 0.9805510706095325);
      expect(r.event, isNotNull);
      expect(r.event!.status, MsEventStatus.pending);
      expect(r.event!.shortId, '3f54285b');

      // 倒计时逻辑：deadline 为当前时间 +20 秒时应剩余约 20 秒
      final now = DateTime.now().millisecondsSinceEpoch / 1000;
      final fresh = MsEvent(
          id: 'x', status: MsEventStatus.pending,
          createdAt: now, deadline: now + 20);
      expect(fresh.remainingSeconds, inInclusiveRange(19, 20));
    });

    test('非跌倒时 event 为 null，状态映射正确', () {
      final r = PredictResult.fromJson(
          {'label': 'non_fall', 'score': 0.01, 'threshold': 0.2, 'event': null});
      expect(r.isSuspectedFall, isFalse);
      expect(r.event, isNull);
      expect(MsEventStatusX.from('simulated_notification'),
          MsEventStatus.simulatedNotification);
      expect(MsEventStatusX.from('help_requested').terminal, isTrue);
      expect(MsEventStatusX.from('pending').terminal, isFalse);
    });
  });
}
