import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:yian_app/ui/fall_confirm_dialog.dart';
import 'package:yian_app/ui/home_screen.dart';
import 'package:yian_app/ui/live_tab.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yian_app/ble/band_protocol.dart';
import 'package:yian_app/ble/ble_service.dart';
import 'package:yian_app/data/model_service_client.dart';
import 'package:yian_app/models/models.dart';
import 'package:yian_app/services/tts_service.dart';
import 'package:yian_app/state/app_state.dart';

class FakeApi extends ModelServiceClient {
  FakeApi() : super(baseUrl: 'http://localhost');
  final ids = <String>[];
  final cancelled = <String>[];
  Completer<void>? gate;
  bool fail = false;
  bool failCancel = false;
  bool legacy = false;
  final stored = <String, MsEvent>{};
  @override
  Future<bool> ping() async => false;
  @override
  Future<MsEvent> createSos(String id) async {
    ids.add(id);
    stored.putIfAbsent(
      id,
      () => MsEvent(
        id: id,
        kind: 'sos',
        status: legacy ? MsEventStatus.pending : MsEventStatus.helpRequested,
        createdAt: 0,
        deadline: 0,
      ),
    );
    if (fail) throw TimeoutException('response lost');
    if (gate != null) await gate!.future;
    return stored[id]!;
  }

  @override
  Future<MsEvent> cancelSos(String id) async {
    if (failCancel) throw TimeoutException('cancel response lost');
    cancelled.add(id);
    return stored[id] = stored[id]!.copyWith(
      status: MsEventStatus.cancelled,
      reason: 'wearer_cancelled',
    );
  }
}

class FakeSpeech extends TtsService {
  final spoken = <String>[];
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }

  @override
  Future<void> stop() async {}
}

class TestBand extends BleService {
  final controller = StreamController<BandFrame>.broadcast(sync: true);
  final parser = BandProtocolParser();
  final sent = <String>[];
  @override
  Future<void> send(List<int> bytes) async {
    sent.add(String.fromCharCodes(bytes));
  }

  @override
  Stream<BandFrame> get frames => controller.stream;
  void receive(String chunk) {
    for (final frame in parser.push(chunk.codeUnits)) {
      controller.add(frame);
    }
  }

  @override
  void dispose() {
    controller.close();
    super.dispose();
  }
}

BandFrame event(String kind, int seq) => BandFrame('ev', {'k': kind, 'q': seq});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeApi api;
  late FakeSpeech speech;
  late TestBand band;
  late AppState state;
  bool stateDisposed = false;
  setUp(() {
    stateDisposed = false;
    api = FakeApi();
    speech = FakeSpeech();
    band = TestBand();
    state = AppState(client: api, band: band, speech: speech);
  });
  tearDown(() {
    if (!stateDisposed) state.dispose();
  });

  test(
    'SOS alarms immediately without waiting for cloud or prediction',
    () async {
      api.gate = Completer<void>();
      state.predicting = true;
      final sending = state.handleBandEvent(event('sos', 1));
      expect(state.activeEvent!.status, MsEventStatus.helpRequested);
      expect(state.events.single.result, isNull);
      expect(speech.spoken.single, contains('紧急求助'));
      expect(state.sosNeedsSync(state.activeEvent!.id), isTrue);
      api.gate!.complete();
      await sending;
      expect(state.sosNeedsSync(state.activeEvent!.id), isFalse);
      await state.handleBandEvent(event('sos', 1));
      expect(api.ids, hasLength(1));
    },
  );

  test('cancel before create response updates guardian immediately and persists later', () async {
    api.gate = Completer<void>();
    final sending = state.handleBandEvent(event('sos', 1));
    final cancelling = state.handleBandEvent(event('cancel', 2));
    expect(state.activeEvent!.status, MsEventStatus.cancelled);
    expect(speech.spoken.last, contains('老人已取消'));
    api.gate!.complete();
    await Future.wait([sending, cancelling]);
    expect(state.events.single.event.status, MsEventStatus.cancelled);
    expect(api.stored.values.single.status, MsEventStatus.cancelled);
  });

  test('failed cloud submission retains alarm and retry reuses id', () async {
    api.fail = true;
    await state.sendSos();
    final id = state.activeEvent!.id;
    expect(state.activeEvent!.status, MsEventStatus.helpRequested);
    expect(state.lastError, contains('云端同步未确认'));
    state.clearMessages();
    expect(state.sosSyncError(id), contains('response lost'));
    api.fail = false;
    await state.retrySosSync(id);
    expect(api.ids, [id, id]);
    expect(state.events, hasLength(1));
    expect(state.sosNeedsSync(id), isFalse);
  });

  test(
    'cancel after guardian dismissed alarm still updates retained record',
    () async {
      await state.sendSos();
      state.activeEvent = null;
      await state.handleBandEvent(event('cancel', 2));
      expect(state.activeEvent!.status, MsEventStatus.cancelled);
      expect(state.events, hasLength(1));
      expect(api.cancelled, hasLength(1));
    },
  );

  test(
    'failed cancellation sync retains local cancellation and can retry',
    () async {
      await state.sendSos();
      api.failCancel = true;
      await state.handleBandEvent(event('cancel', 2));
      final id = state.activeEvent!.id;
      expect(state.activeEvent!.status, MsEventStatus.cancelled);
      expect(state.sosNeedsSync(id), isTrue);
      api.failCancel = false;
      await state.retrySosSync(id);
      expect(api.stored[id]!.status, MsEventStatus.cancelled);
      expect(state.sosNeedsSync(id), isFalse);
    },
  );

  test('new SOS after a failed sync creates a new local alarm', () async {
    api.fail = true;
    await state.sendSos();
    final first = state.activeEvent!.id;
    api.fail = false;
    await state.handleBandEvent(event('sos', 2));
    expect(state.activeEvent!.id, isNot(first));
    expect(state.activeEvent!.status, MsEventStatus.helpRequested);
    expect(state.events, hasLength(2));
    expect(api.ids, [first, state.activeEvent!.id]);
    expect(speech.spoken, hasLength(2));
    expect(state.sosNeedsSync(first), isTrue);
  });

  test('new SOS after cancellation creates a new alarm', () async {
    await state.sendSos();
    await state.handleBandEvent(event('cancel', 2));
    await state.handleBandEvent(event('sos', 3));
    expect(state.events, hasLength(2));
    expect(state.events.first.event.status, MsEventStatus.helpRequested);
    expect(state.events.last.event.status, MsEventStatus.cancelled);
  });

  test('old server cannot silently reinstate confirmation flow', () async {
    api.legacy = true;
    await state.sendSos();
    expect(state.activeEvent!.status, MsEventStatus.helpRequested);
    expect(state.lastError, contains('更新服务端'));
  });

  testWidgets(
    'guardian sees alarm and cancellation with no confirmation or countdown',
    (tester) async {
      await state.sendSos();
      final ev = state.activeEvent!;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(home: FallConfirmDialog(event: ev)),
        ),
      );
      expect(find.text('老人紧急求助'), findsOneWidget);
      expect(find.text('我已知晓'), findsOneWidget);
      expect(find.text('我没事'), findsNothing);
      expect(find.text('立即求助'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await state.handleBandEvent(event('cancel', 2));
      await tester.pump();
      expect(find.text('老人已取消 SOS'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'BLE bytes reach HomeScreen; network failure never blocks repeat alerts',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      PackageInfo.setMockInitialValues(
        appName: 'test',
        packageName: 'test',
        version: '0.2.4',
        buildNumber: '6',
        buildSignature: '',
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await state.init();
      api.fail = true;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: const MaterialApp(home: HomeScreen()),
        ),
      );
      await tester.pump();
      // 模拟上一条 raw 发送中断，下一条 SOS 被拆成两个 BLE 包。
      band.receive('{"t":"raw","s":[0,');
      band.receive('{"t":"ev","k":"sos",');
      band.receive('"q":1}\n');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('老人紧急求助'), findsOneWidget);
      expect(find.textContaining('response lost'), findsWidgets);
      final first = state.activeEvent!.id;
      expect(speech.spoken, hasLength(1));
      await tester.tap(find.text('我已知晓'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('老人紧急求助'), findsNothing);
      band.receive('{"t":"ev","k":"sos","q":2}\n');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('老人紧急求助'), findsOneWidget);
      expect(state.activeEvent!.id, isNot(first));
      expect(speech.spoken, hasLength(2));
      expect(state.events, hasLength(2));
      // 同一帧重传不重复报警；新帧不受旧云端失败影响。
      band.receive('{"t":"ev","k":"sos","q":2}\n');
      await tester.pump();
      expect(state.events, hasLength(2));
      // 旧弹窗退场过程中再收到 SOS，新事件必须仍能显示。
      await tester.tap(find.text('我已知晓'));
      band.receive('{"t":"ev","k":"sos","q":3}\n');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('老人紧急求助'), findsOneWidget);
      expect(state.events, hasLength(3));
      expect(speech.spoken, hasLength(3));
      band.receive('{"t":"ev","k":"cancel","q":4}\n');
      await tester.pump();
      expect(find.text('老人已取消 SOS'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
      stateDisposed = true;
    },
  );

  testWidgets('home SOS taps to start and holds 1.5 seconds to cancel', (
    tester,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: const MaterialApp(home: Scaffold(body: LiveTab())),
      ),
    );
    await tester.scrollUntilVisible(find.text('SOS 求助'), 300);
    await tester.tap(find.text('SOS 求助'));
    await tester.pumpAndSettle();
    expect(state.sosAlerting, isTrue);
    expect(find.text('SOS 告警中'), findsOneWidget);
    var gesture = await tester.startGesture(
      tester.getCenter(find.text('SOS 告警中')),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 800));
    expect(state.sosAlerting, isTrue); // early release must not cancel later
    gesture = await tester.startGesture(tester.getCenter(find.text('SOS 告警中')));
    await tester.pump(const Duration(milliseconds: 1490));
    expect(state.sosAlerting, isTrue);
    await tester.pump(const Duration(milliseconds: 60));
    expect(state.sosAlerting, isFalse);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('SOS 求助'), findsOneWidget);
    expect(band.sent.last, '{"t":"sos-off"}\n');
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'phone cancellation sends stop immediately while create is pending',
    () async {
      api.gate = Completer<void>();
      final sending = state.sendSos();
      final id = state.activeEvent!.id;
      final cancelling = state.cancelSosByWearer();
      expect(state.sosAlerting, isFalse);
      expect(state.activeEvent, isNull);
      expect(state.sosNeedsSync(id), isTrue);
      expect(band.sent, ['{"t":"sos-on"}\n', '{"t":"sos-off"}\n']);
      api.gate!.complete();
      await Future.wait([sending, cancelling]);
      expect(api.stored[id]!.status, MsEventStatus.cancelled);
      expect(state.sosNeedsSync(id), isFalse);
    },
  );

  test(
    'phone cancellation failure stays retryable after a successful create',
    () async {
      await state.sendSos();
      final id = state.activeEvent!.id;
      api.failCancel = true;
      await state.cancelSosByWearer();
      expect(state.sosAlerting, isFalse);
      expect(state.sosNeedsSync(id), isTrue);
      expect(state.sosSyncError(id), contains('cancel response lost'));
      api.failCancel = false;
      await state.retrySosSync(id);
      expect(api.stored[id]!.status, MsEventStatus.cancelled);
      expect(state.sosNeedsSync(id), isFalse);
    },
  );

  test('band SOS does not echo a second start command to the band', () async {
    await state.handleBandEvent(event('sos', 99));
    expect(band.sent, isEmpty);
    expect(state.sosAlerting, isTrue);
  });

  test('cancel without an alarm does not fabricate a record', () async {
    await state.handleBandEvent(event('cancel', 3));
    expect(api.cancelled, isEmpty);
    expect(state.events, isEmpty);
  });
}
