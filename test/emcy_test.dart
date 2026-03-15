/// Unit tests for EmcyManager.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:canopen_client/canopen_client.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Fake adapter ──────────────────────────────────────────────────────────────

class FakeCanAdapter implements ICanAdapter {
  final StreamController<CanMessage> _rxCtrl =
      StreamController<CanMessage>.broadcast();

  @override
  Stream<CanMessage> get rxFrames => _rxCtrl.stream;
  @override
  Future<List<String>> listPorts() async => [];
  @override
  Future<void> connect(String port, BusSpeed speed) async {}
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> send(CanMessage message) async {}
  @override
  void dispose() => _rxCtrl.close();

  void inject(CanMessage message) => _rxCtrl.add(message);
}

// ── Frame builder helper ──────────────────────────────────────────────────────

/// Builds an 8-byte EMCY payload for [nodeId].
CanMessage emcyFrame(
  int nodeId, {
  required int errorCode,
  required int errorRegister,
  List<int> mfrData = const [0, 0, 0, 0, 0],
}) {
  assert(mfrData.length == 5);
  final data = Uint8List(8);
  data[0] = errorCode & 0xFF;
  data[1] = (errorCode >> 8) & 0xFF;
  data[2] = errorRegister;
  for (var i = 0; i < 5; i++) {
    data[3 + i] = mfrData[i];
  }
  return CanMessage(cobId: 0x080 + nodeId, data: data);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late FakeCanAdapter adapter;
  late EmcyManager emcy;

  setUp(() {
    adapter = FakeCanAdapter();
    emcy = EmcyManager(adapter);
  });

  tearDown(() {
    emcy.dispose();
    adapter.dispose();
  });

  // ── Parsing ───────────────────────────────────────────────────────────────

  group('EMCY frame parsing', () {
    test('parses nodeId, errorCode, errorRegister, mfrData correctly',
        () async {
      EmcyMessage? received;
      emcy.registerEmcyHandler(5, (m) => received = m);

      adapter.inject(emcyFrame(5,
          errorCode: 0x4210, errorRegister: 0x08, mfrData: [1, 2, 3, 4, 5]));
      await Future<void>.delayed(Duration.zero);

      expect(received, isNotNull);
      expect(received!.nodeId, equals(5));
      expect(received!.errorCode, equals(0x4210));
      expect(received!.errorRegister, equals(0x08));
      expect(received!.mfrSpecificData, equals([1, 2, 3, 4, 5]));
    });

    test('ignores frames with cobId outside 0x081–0x0FF', () async {
      var fired = false;
      emcy.registerEmcyHandler(5, (_) => fired = true);

      adapter
          .inject(CanMessage(cobId: 0x080, data: Uint8List(8))); // SYNC COB-ID
      adapter.inject(CanMessage(cobId: 0x100, data: Uint8List(8))); // too high
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });

    test('ignores frames shorter than 8 bytes', () async {
      var fired = false;
      emcy.registerEmcyHandler(5, (_) => fired = true);

      adapter.inject(CanMessage(cobId: 0x085, data: Uint8List(7)));
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });

    test('timestamp is set to approximately now', () async {
      EmcyMessage? received;
      emcy.registerEmcyHandler(3, (m) => received = m);

      final before = DateTime.now();
      adapter.inject(emcyFrame(3, errorCode: 0x1000, errorRegister: 0x01));
      await Future<void>.delayed(Duration.zero);
      final after = DateTime.now();

      expect(
          received!.timestamp.isAfter(before) ||
              received!.timestamp.isAtSameMomentAs(before),
          isTrue);
      expect(
          received!.timestamp.isBefore(after) ||
              received!.timestamp.isAtSameMomentAs(after),
          isTrue);
    });
  });

  // ── registerEmcyHandler ───────────────────────────────────────────────────

  group('registerEmcyHandler', () {
    test('fires handler when frame for registered node arrives', () async {
      var fired = false;
      emcy.registerEmcyHandler(7, (_) => fired = true);

      adapter.inject(emcyFrame(7, errorCode: 0x8100, errorRegister: 0x10));
      await Future<void>.delayed(Duration.zero);

      expect(fired, isTrue);
    });

    test('does not fire for a different node', () async {
      var fired = false;
      emcy.registerEmcyHandler(7, (_) => fired = true);

      adapter.inject(emcyFrame(8, errorCode: 0x8100, errorRegister: 0x10));
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });

    test('replacing handler for same node uses new handler only', () async {
      var firstFired = false;
      var secondFired = false;
      emcy.registerEmcyHandler(2, (_) => firstFired = true);
      emcy.registerEmcyHandler(2, (_) => secondFired = true);

      adapter.inject(emcyFrame(2, errorCode: 0x5000, errorRegister: 0x01));
      await Future<void>.delayed(Duration.zero);

      expect(firstFired, isFalse);
      expect(secondFired, isTrue);
    });
  });

  // ── unregisterEmcyHandler ─────────────────────────────────────────────────

  group('unregisterEmcyHandler', () {
    test('removed handler no longer fires', () async {
      var fired = false;
      emcy.registerEmcyHandler(4, (_) => fired = true);
      emcy.unregisterEmcyHandler(4);

      adapter.inject(emcyFrame(4, errorCode: 0x3100, errorRegister: 0x04));
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });
  });

  // ── getRecentEmcy / ring buffer ───────────────────────────────────────────

  group('getRecentEmcy', () {
    test('returns empty list when no messages received', () {
      expect(emcy.getRecentEmcy(9), isEmpty);
    });

    test('returns all messages when fewer than count', () async {
      adapter.inject(emcyFrame(1, errorCode: 0x1000, errorRegister: 0x01));
      adapter.inject(emcyFrame(1, errorCode: 0x2000, errorRegister: 0x02));
      await Future<void>.delayed(Duration.zero);

      final recent = emcy.getRecentEmcy(1, count: 10);
      expect(recent, hasLength(2));
    });

    test('returns only the last count messages', () async {
      for (var i = 0; i < 5; i++) {
        adapter.inject(emcyFrame(1, errorCode: 0x1000 + i, errorRegister: 0));
        await Future<void>.delayed(Duration.zero);
      }

      final recent = emcy.getRecentEmcy(1, count: 3);
      expect(recent, hasLength(3));
      expect(recent[0].errorCode, equals(0x1002));
      expect(recent[1].errorCode, equals(0x1003));
      expect(recent[2].errorCode, equals(0x1004));
    });

    test('ring buffer does not exceed 50 entries', () async {
      for (var i = 0; i < 55; i++) {
        adapter.inject(emcyFrame(6, errorCode: i, errorRegister: 0));
        await Future<void>.delayed(Duration.zero);
      }

      final all = emcy.getRecentEmcy(6, count: 100);
      expect(all.length, equals(50));
      // Oldest retained entry should be the 6th (index 5 of 55 total).
      expect(all.first.errorCode, equals(5));
      expect(all.last.errorCode, equals(54));
    });
  });

  // ── clearHistory ──────────────────────────────────────────────────────────

  group('clearHistory', () {
    test('empties history for the specified node', () async {
      adapter.inject(emcyFrame(3, errorCode: 0x1000, errorRegister: 0x01));
      await Future<void>.delayed(Duration.zero);

      emcy.clearHistory(3);

      expect(emcy.getRecentEmcy(3), isEmpty);
    });
  });

  // ── errorCodeDescription ──────────────────────────────────────────────────

  group('EmcyMessage.errorCodeDescription', () {
    EmcyMessage makeMsg(int errorCode) => EmcyMessage(
          nodeId: 1,
          errorCode: errorCode,
          errorRegister: 0,
          mfrSpecificData: Uint8List(5),
          timestamp: DateTime.now(),
        );

    test('0x0000 → No error', () {
      expect(makeMsg(0x0000).errorCodeDescription, equals('No error'));
    });

    test('0x1xxx → Generic error', () {
      expect(makeMsg(0x1000).errorCodeDescription, contains('Generic'));
    });

    test('0x2xxx → Current error', () {
      expect(makeMsg(0x2100).errorCodeDescription, contains('Current'));
    });

    test('0x3xxx → Voltage error', () {
      expect(makeMsg(0x3200).errorCodeDescription, contains('Voltage'));
    });

    test('0x4xxx → Temperature error', () {
      expect(makeMsg(0x4310).errorCodeDescription, contains('Temperature'));
    });

    test('0x5xxx → Device hardware error', () {
      expect(makeMsg(0x5000).errorCodeDescription, contains('hardware'));
    });

    test('0x6xxx → Device software error', () {
      expect(makeMsg(0x6000).errorCodeDescription, contains('software'));
    });

    test('0x7xxx → Additional modules error', () {
      expect(makeMsg(0x7300).errorCodeDescription, contains('Additional'));
    });

    test('0x8xxx → Monitoring error', () {
      expect(makeMsg(0x8100).errorCodeDescription, contains('Monitoring'));
    });

    test('0x9xxx → External error', () {
      expect(makeMsg(0x9000).errorCodeDescription, contains('External'));
    });

    test('0xFxxx → Device specific error', () {
      expect(makeMsg(0xFF00).errorCodeDescription, contains('specific'));
    });

    test('unknown group returns non-empty string', () {
      expect(makeMsg(0xA000).errorCodeDescription, isNotEmpty);
    });
  });
}
