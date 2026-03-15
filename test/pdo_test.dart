/// Unit tests for PdoManager.
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

  @override
  Stream<CanMessage> get rxFrames => _rxCtrl.stream;

  @override
  Future<List<String>> listPorts() async => [];

  @override
  Future<void> connect(String port, BusSpeed speed) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> send(CanMessage message) async => sent.add(message);

  @override
  void dispose() => _rxCtrl.close();

  void inject(CanMessage message) => _rxCtrl.add(message);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late FakeCanAdapter adapter;
  late PdoManager pdo;

  setUp(() {
    adapter = FakeCanAdapter();
    pdo = PdoManager(adapter);
  });

  tearDown(() {
    pdo.dispose();
    adapter.dispose();
  });

  // ── sendPdo ───────────────────────────────────────────────────────────────

  group('sendPdo', () {
    test('sends frame with correct COB-ID and data', () async {
      final data = Uint8List.fromList([0x01, 0x02, 0x03]);
      await pdo.sendPdo(0x185, data);

      expect(adapter.sent, hasLength(1));
      expect(adapter.sent[0].cobId, equals(0x185));
      expect(adapter.sent[0].data, equals(data));
    });

    test('sends 1-byte frame', () async {
      await pdo.sendPdo(0x205, Uint8List.fromList([0xFF]));

      expect(adapter.sent[0].data, equals([0xFF]));
    });

    test('sends 8-byte frame (maximum)', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      await pdo.sendPdo(0x285, data);

      expect(adapter.sent[0].data, equals(data));
    });

    test('throws CanOpenException for empty data', () async {
      await expectLater(
        pdo.sendPdo(0x185, Uint8List(0)),
        throwsA(isA<CanOpenException>()),
      );
      expect(adapter.sent, isEmpty);
    });

    test('throws CanOpenException for data > 8 bytes', () async {
      await expectLater(
        pdo.sendPdo(0x185, Uint8List(9)),
        throwsA(isA<CanOpenException>()),
      );
      expect(adapter.sent, isEmpty);
    });
  });

  // ── registerPdoCallback ───────────────────────────────────────────────────

  group('registerPdoCallback', () {
    test('fires callback when matching frame arrives', () async {
      Uint8List? received;
      pdo.registerPdoCallback(0x185, (data) => received = data);

      final payload = Uint8List.fromList([0xAA, 0xBB]);
      adapter.inject(CanMessage(cobId: 0x185, data: payload));
      await Future<void>.delayed(Duration.zero);

      expect(received, equals(payload));
    });

    test('fires multiple callbacks registered for same COB-ID', () async {
      final results = <int>[];
      pdo.registerPdoCallback(0x185, (_) => results.add(1));
      pdo.registerPdoCallback(0x185, (_) => results.add(2));

      adapter
          .inject(CanMessage(cobId: 0x185, data: Uint8List.fromList([0x00])));
      await Future<void>.delayed(Duration.zero);

      expect(results, equals([1, 2]));
    });

    test('callbacks for different COB-IDs do not cross-fire', () async {
      var fired185 = false;
      var fired205 = false;
      pdo.registerPdoCallback(0x185, (_) => fired185 = true);
      pdo.registerPdoCallback(0x205, (_) => fired205 = true);

      adapter
          .inject(CanMessage(cobId: 0x205, data: Uint8List.fromList([0x01])));
      await Future<void>.delayed(Duration.zero);

      expect(fired185, isFalse);
      expect(fired205, isTrue);
    });

    test('frame on unregistered COB-ID is silently ignored', () async {
      var fired = false;
      pdo.registerPdoCallback(0x185, (_) => fired = true);

      adapter
          .inject(CanMessage(cobId: 0x999, data: Uint8List.fromList([0x01])));
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });

    test('callback receives correct data bytes', () async {
      final received = <Uint8List>[];
      pdo.registerPdoCallback(0x385, received.add);

      final payload = Uint8List.fromList([10, 20, 30, 40]);
      adapter.inject(CanMessage(cobId: 0x385, data: payload));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received[0], equals(payload));
    });
  });

  // ── unregisterAllCallbacks ────────────────────────────────────────────────

  group('unregisterAllCallbacks', () {
    test('prevents further callback invocations for that COB-ID', () async {
      var fired = false;
      pdo.registerPdoCallback(0x185, (_) => fired = true);
      pdo.unregisterAllCallbacks(0x185);

      adapter
          .inject(CanMessage(cobId: 0x185, data: Uint8List.fromList([0x01])));
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });

    test('unregistering one COB-ID does not affect others', () async {
      var fired185 = false;
      var fired205 = false;
      pdo.registerPdoCallback(0x185, (_) => fired185 = true);
      pdo.registerPdoCallback(0x205, (_) => fired205 = true);

      pdo.unregisterAllCallbacks(0x185);

      adapter
          .inject(CanMessage(cobId: 0x205, data: Uint8List.fromList([0x01])));
      await Future<void>.delayed(Duration.zero);

      expect(fired185, isFalse);
      expect(fired205, isTrue);
    });

    test('is safe to call for a COB-ID with no registered callbacks', () {
      expect(() => pdo.unregisterAllCallbacks(0xABC), returnsNormally);
    });
  });
}
