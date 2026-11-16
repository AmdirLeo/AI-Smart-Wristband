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
  final choices = <bool>[];
  Completer<void>? gate;
  bool fail = false;
  bool missing = false;
  MsEvent? stored;
  @override
  Future<MsEvent> createSos(String requestId) async {
    ids.add(requestId);
    stored ??= MsEvent(
      id: requestId,
      kind: 'sos',
      status: MsEventStatus.pending,
      createdAt: 0,
      deadline: DateTime.now().millisecondsSinceEpoch / 1000 + 20,
    );
    if (fail) throw TimeoutException('response lost');
    if (gate != null) await gate!.future;
    return stored!;
  }

  @override
  Future<MsEvent> confirm(String id, {required bool safe}) async {
    if (missing) throw ApiException(statusCode: 404, message: 'expired');
    expect(id, stored!.id);
    choices.add(safe);
    stored = stored!.copyWith(
      status: safe ? MsEventStatus.safe : MsEventStatus.helpRequested,
    );
    return stored!;
  }
}

class FakeSpeech extends TtsService {
  @override
  Future<void> speak(String text) async {}
}

class FakeBand extends BleService {
  int sent = 0;
  @override
  Future<void> send(List<int> bytes) async {
    sent++;
  }
}

BandFrame event(String kind, int seq) => BandFrame('ev', {'k': kind, 'q': seq});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeApi api;
  late FakeBand band;
  late AppState state;
  setUp(() {
    api = FakeApi();
    band = FakeBand();
    state = AppState(client: api, band: band, speech: FakeSpeech());
  });
  tearDown(() => state.dispose());

  test('BLE SOS creates a real event once; duplicate is ignored; cancel confirms safe', () async {
    await state.handleBandEvent(event('sos', 1));
    await state.handleBandEvent(event('sos', 1));
    expect(api.ids, hasLength(1));
    expect(state.activeEvent!.isSos, isTrue);
    expect(state.events.single.result, isNull);
    await state.handleBandEvent(event('cancel', 2));
    expect(api.choices, [true]);
    expect(state.activeEvent!.status, MsEventStatus.safe);
    expect(band.sent, 1);
  });
  test('cancel arriving before create response waits for its event', () async {
    api.gate = Completer<void>();
    final sos = state.handleBandEvent(event('sos', 1));
    final cancel = state.handleBandEvent(event('cancel', 2));
    await Future<void>.delayed(Duration.zero);
    expect(api.ids, hasLength(1));
    expect(api.choices, isEmpty);
    api.gate!.complete();
    await Future.wait([sos, cancel]);
    expect(state.events.single.event.status, MsEventStatus.safe);
  });
  test('lost response reports failure and retry reuses request id', () async {
    api.fail = true;
    await state.sendSos();
    expect(state.activeEvent, isNull);
    expect(state.lastError, contains('提交未确认'));
    api.fail = false;
    await state.sendSos();
    expect(api.ids[0], api.ids[1]);
    expect(state.events, hasLength(1));
    await state.confirmEvent(state.activeEvent!, safe: false);
    expect(state.activeEvent!.status, MsEventStatus.helpRequested);
  });
  test('cancel after a lost SOS response recovers same event', () async {
    api.fail = true;
    await state.handleBandEvent(event('sos', 1));
    api.fail = false;
    await state.handleBandEvent(event('cancel', 2));
    expect(api.ids[0], api.ids[1]);
    expect(state.activeEvent!.status, MsEventStatus.safe);
  });
  test('phone SOS in flight can be cancelled by hardware button', () async {
    api.gate = Completer<void>();
    final submit = state.sendSos();
    final cancel = state.handleBandEvent(event('cancel', 9));
    await Future<void>.delayed(Duration.zero);
    expect(api.choices, isEmpty);
    api.gate!.complete();
    await Future.wait([submit, cancel]);
    expect(api.ids, hasLength(1));
    expect(state.activeEvent!.status, MsEventStatus.safe);
  });
  test('failed recovery keeps cancellation uncertain', () async {
    api.fail = true;
    await state.handleBandEvent(event('sos', 1));
    await state.handleBandEvent(event('cancel', 2));
    expect(api.ids[0], api.ids[1]);
    expect(api.choices, isEmpty);
    expect(state.lastError, contains('提交未确认'));
    expect(state.lastInfo, isNull);
  });
  testWidgets('expired event leaves a dismissible dialog', (tester) async {
    await state.sendSos();
    final ev = state.activeEvent!;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(home: FallConfirmDialog(event: ev)),
      ),
    );
    expect(find.text('SOS 求助确认'), findsOneWidget);
    api.missing = true;
    await state.confirmEvent(ev, safe: true);
    await tester.pump();
    expect(find.text('事件已失效'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  test('cancel without pending event does not fabricate success', () async {
    await state.handleBandEvent(event('cancel', 3));
    expect(api.choices, isEmpty);
    expect(state.lastInfo, contains('没有待取消'));
  });
}
