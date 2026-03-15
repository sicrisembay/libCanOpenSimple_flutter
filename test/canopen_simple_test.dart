/// Integration tests for the CanOpenSimple facade.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:canopen_client/canopen_client.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Fake adapter ──────────────────────────────────────────────────────────────

class FakeCanAdapter implements ICanAdapter {
  final StreamController<CanMessage> _rxCtrl =
      StreamController<CanMessage>.broadcast();

  final List<CanMessage> sent = [];
  bool connectCalled = false;
  bool disconnectCalled = false;
  bool disposeCalled = false;

  CanMessage? Function(CanMessage)? autoReplyWith;

  @override
  Stream<CanMessage> get rxFrames => _rxCtrl.stream;

  @override
  Future<List<String>> listPorts() async => ['COM3', 'COM4'];

  @override
  Future<void> connect(String port, BusSpeed speed) async =>
      connectCalled = true;

  @override
  Future<void> disconnect() async => disconnectCalled = true;

  @override
  Future<void> send(CanMessage message) async {
    sent.add(message);
    if (autoReplyWith != null) {
      final resp = autoReplyWith!(message);
      if (resp != null) scheduleMicrotask(() => _rxCtrl.add(resp));
    }
  }

  @override
  void dispose() {
    disposeCalled = true;
    _rxCtrl.close();
  }

  void inject(CanMessage message) => _rxCtrl.add(message);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Builds an expedited SDO upload response (cs=0x43, 1-byte value in byte[4]).
CanMessage sdoUploadResp(int nodeId, int value) {
  final data = Uint8List(8);
  data[0] = 0x4F; // cs=2, e=1, s=1, n=3 (1 byte)
  data[4] = value & 0xFF;
  return CanMessage(cobId: 0x580 + nodeId, data: data);
}

/// Builds an SDO download ACK (cs=0x60).
CanMessage sdoDownloadAck(int nodeId) {
  final data = Uint8List(8)..[0] = 0x60;
  return CanMessage(cobId: 0x580 + nodeId, data: data);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late FakeCanAdapter adapter;
  late CanOpenSimple canopen;

  setUp(() {
    adapter = FakeCanAdapter();
    canopen = CanOpenSimple(adapter: adapter);
  });

  tearDown(() {
    canopen.dispose();
  });

  // ── Connection lifecycle ───────────────────────────────────────────────────

  group('connect / disconnect / dispose', () {
    test('isConnected is false before connect()', () {
      expect(canopen.isConnected, isFalse);
    });

    test('connect() sets isConnected to true and calls adapter.connect',
        () async {
      await canopen.connect('COM3', BusSpeed.baud1M);

      expect(canopen.isConnected, isTrue);
      expect(adapter.connectCalled, isTrue);
    });

    test('disconnect() sets isConnected to false and calls adapter.disconnect',
        () async {
      await canopen.connect('COM3', BusSpeed.baud1M);
      await canopen.disconnect();

      expect(canopen.isConnected, isFalse);
      expect(adapter.disconnectCalled, isTrue);
    });

    test('dispose() without connect does not throw', () {
      expect(() => canopen.dispose(), returnsNormally);
    });

    test('listPorts() returns port list from adapter', () async {
      final ports = await canopen.listPorts();
      expect(ports, equals(['COM3', 'COM4']));
    });
  });

  // ── StateError before connect ─────────────────────────────────────────────

  group('methods before connect() throw StateError', () {
    test('sdoReadU8 throws StateError', () {
      expect(
        () => canopen.sdoReadU8(1, 0x1000, 0),
        throwsA(isA<StateError>()),
      );
    });

    test('sdoWriteU16 throws StateError', () {
      expect(
        () => canopen.sdoWriteU16(1, 0x1017, 0, 500),
        throwsA(isA<StateError>()),
      );
    });

    test('nmtStart throws StateError', () {
      expect(() => canopen.nmtStart(1), throwsA(isA<StateError>()));
    });

    test('sendPdo throws StateError', () {
      expect(
        () => canopen.sendPdo(0x200, Uint8List.fromList([1])),
        throwsA(isA<StateError>()),
      );
    });

    test('sendSync throws StateError', () {
      expect(() => canopen.sendSync(), throwsA(isA<StateError>()));
    });

    test('registerEmcyHandler throws StateError', () {
      expect(
        () => canopen.registerEmcyHandler(1, (_) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('lssSwitchStateGlobal throws StateError', () {
      expect(
        () => canopen.lssSwitchStateGlobal(LssMode.configuration),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ── SDO proxy ─────────────────────────────────────────────────────────────

  group('SDO proxy', () {
    setUp(() async => canopen.connect('COM3', BusSpeed.baud1M));

    test('sdoReadU8 delegates to SdoClient and returns value', () async {
      adapter.autoReplyWith = (_) => sdoUploadResp(5, 42);

      final result = await canopen.sdoReadU8(5, 0x1000, 0);

      expect(result, equals(42));
    });

    test('sdoWriteU8 delegates to SdoClient and sends frame', () async {
      adapter.autoReplyWith = (_) => sdoDownloadAck(5);

      await canopen.sdoWriteU8(5, 0x6040, 0, 0x0F);

      expect(adapter.sent[0].cobId, equals(0x600 + 5));
      expect(adapter.sent[0].data[0], equals(0x2F)); // expedited, 1 byte
    });
  });

  // ── NMT proxy ─────────────────────────────────────────────────────────────

  group('NMT proxy', () {
    setUp(() async => canopen.connect('COM3', BusSpeed.baud1M));

    test('nmtStart sends NMT frame on COB-ID 0x000', () async {
      await canopen.nmtStart(5);

      expect(adapter.sent[0].cobId, equals(0x000));
      expect(adapter.sent[0].data[0], equals(0x01)); // start
      expect(adapter.sent[0].data[1], equals(5));
    });

    test('getNodeState returns unknown before any heartbeat', () async {
      expect(canopen.getNodeState(5), equals(NmtState.unknown));
    });

    test('getNodeState reflects received heartbeat', () async {
      adapter
          .inject(CanMessage(cobId: 0x705, data: Uint8List.fromList([0x05])));
      await Future<void>.delayed(Duration.zero);

      expect(canopen.getNodeState(5), equals(NmtState.operational));
    });
  });

  // ── PDO proxy ─────────────────────────────────────────────────────────────

  group('PDO proxy', () {
    setUp(() async => canopen.connect('COM3', BusSpeed.baud1M));

    test('sendPdo sends frame with correct COB-ID', () async {
      await canopen.sendPdo(0x185, Uint8List.fromList([1, 2, 3]));

      expect(adapter.sent[0].cobId, equals(0x185));
    });

    test('registerPdoCallback fires on incoming frame', () async {
      Uint8List? received;
      canopen.registerPdoCallback(0x285, (d) => received = d);

      final payload = Uint8List.fromList([0xAA, 0xBB]);
      adapter.inject(CanMessage(cobId: 0x285, data: payload));
      await Future<void>.delayed(Duration.zero);

      expect(received, equals(payload));
    });

    test('unregisterAllPdoCallbacks prevents further callbacks', () async {
      var fired = false;
      canopen.registerPdoCallback(0x385, (_) => fired = true);
      canopen.unregisterAllPdoCallbacks(0x385);

      adapter
          .inject(CanMessage(cobId: 0x385, data: Uint8List.fromList([0x01])));
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });
  });

  // ── SYNC proxy ────────────────────────────────────────────────────────────

  group('SYNC proxy', () {
    setUp(() async => canopen.connect('COM3', BusSpeed.baud1M));

    test('sendSync sends 0-byte frame on COB-ID 0x080', () async {
      await canopen.sendSync();

      expect(adapter.sent[0].cobId, equals(0x080));
      expect(adapter.sent[0].data, isEmpty);
    });

    test('setSyncCounterEnabled + sendSync sends counter byte', () async {
      canopen.setSyncCounterEnabled(true);
      await canopen.sendSync();

      expect(adapter.sent[0].data, equals([0x01]));
    });

    test('registerSyncCallback fires on incoming SYNC', () async {
      int? received;
      canopen.registerSyncCallback((c) => received = c);

      adapter.inject(CanMessage(cobId: 0x080, data: Uint8List.fromList([7])));
      await Future<void>.delayed(Duration.zero);

      expect(received, equals(7));
    });
  });

  // ── EMCY proxy ────────────────────────────────────────────────────────────

  group('EMCY proxy', () {
    setUp(() async => canopen.connect('COM3', BusSpeed.baud1M));

    test('registerEmcyHandler fires on incoming EMCY frame', () async {
      EmcyMessage? received;
      canopen.registerEmcyHandler(3, (m) => received = m);

      final data = Uint8List(8)
        ..[0] = 0x10 // errorCode low
        ..[1] = 0x10 // errorCode high → 0x1010
        ..[2] = 0x01; // errorRegister
      adapter.inject(CanMessage(cobId: 0x083, data: data));
      await Future<void>.delayed(Duration.zero);

      expect(received, isNotNull);
      expect(received!.nodeId, equals(3));
      expect(received!.errorCode, equals(0x1010));
    });

    test('getRecentEmcy returns empty list before any message', () async {
      expect(canopen.getRecentEmcy(5), isEmpty);
    });
  });

  // ── LSS proxy ─────────────────────────────────────────────────────────────

  group('LSS proxy', () {
    setUp(() async => canopen.connect('COM3', BusSpeed.baud1M));

    test('lssSwitchStateGlobal sends correct frame', () async {
      await canopen.lssSwitchStateGlobal(LssMode.configuration);

      expect(adapter.sent[0].cobId, equals(0x7E5));
      expect(adapter.sent[0].data[0], equals(0x04)); // cs
      expect(adapter.sent[0].data[1], equals(0x01)); // configuration mode
    });

    test('lssConfigureNodeId delegates and returns LssError', () async {
      final resp = Uint8List(8)
        ..[0] = lssCsConfigureNodeId
        ..[1] = 0; // success
      adapter.autoReplyWith = (_) => CanMessage(cobId: CobId.lss, data: resp);

      final result = await canopen.lssConfigureNodeId(10);

      expect(result, equals(LssError.success));
    });
  });

  // ── disconnect cleans up ───────────────────────────────────────────────────

  group('disconnect cleans up managers', () {
    test('methods throw StateError after disconnect', () async {
      await canopen.connect('COM3', BusSpeed.baud1M);
      await canopen.disconnect();

      expect(() => canopen.sendSync(), throwsA(isA<StateError>()));
    });

    test('reconnect works after disconnect', () async {
      await canopen.connect('COM3', BusSpeed.baud1M);
      await canopen.disconnect();
      await canopen.connect('COM3', BusSpeed.baud1M);

      expect(canopen.isConnected, isTrue);
    });
  });
}
