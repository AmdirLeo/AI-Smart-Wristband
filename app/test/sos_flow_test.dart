import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:yian_app/ui/fall_confirm_dialog.dart';
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

BandFrame event(String kind, int seq) => BandFrame('ev', {'k': kind, 'q': seq});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeApi api;
  late FakeSpeech speech;
  late AppState state;
  setUp(() {
    api = FakeApi();
    speech = FakeSpeech();
    state = AppState(client: api, band: BleService(), speech: speech);
  });
  tearDown(() => state.dispose());

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

  test('cancel without an alarm does not fabricate a record', () async {
    await state.handleBandEvent(event('cancel', 3));
    expect(api.cancelled, isEmpty);
    expect(state.events, isEmpty);
  });
}
