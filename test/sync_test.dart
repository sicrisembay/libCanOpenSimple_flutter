/// Unit tests for SyncManager.
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
  late SyncManager sync;

  setUp(() {
    adapter = FakeCanAdapter();
    sync = SyncManager(adapter);
  });

  tearDown(() {
    sync.dispose();
    adapter.dispose();
  });

  // ── sendSync without counter ───────────────────────────────────────────────

  group('sendSync without counter', () {
    test('sends 0-byte frame on COB-ID 0x080', () async {
      await sync.sendSync();

      expect(adapter.sent, hasLength(1));
      expect(adapter.sent[0].cobId, equals(0x080));
      expect(adapter.sent[0].data, isEmpty);
    });

    test('multiple calls all send 0-byte frames', () async {
      await sync.sendSync();
      await sync.sendSync();
      await sync.sendSync();

      expect(adapter.sent, hasLength(3));
      for (final msg in adapter.sent) {
        expect(msg.data, isEmpty);
      }
    });
  });

  // ── sendSync with counter ─────────────────────────────────────────────────

  group('sendSync with counter', () {
    setUp(() => sync.setSyncCounterEnabled(true));

    test('first call sends [0x01]', () async {
      await sync.sendSync();
      expect(adapter.sent[0].data, equals([0x01]));
    });

    test('second call sends [0x02]', () async {
      await sync.sendSync();
      await sync.sendSync();
      expect(adapter.sent[1].data, equals([0x02]));
    });

    test('counter increments across multiple calls', () async {
      for (var i = 0; i < 5; i++) {
        await sync.sendSync();
      }
      expect(
          adapter.sent.map((m) => m.data[0]).toList(), equals([1, 2, 3, 4, 5]));
    });

    test('counter wraps from 240 back to 1', () async {
      // Send 240 times to reach max.
      for (var i = 0; i < 240; i++) {
        await sync.sendSync();
      }
      expect(adapter.sent.last.data[0], equals(240));

      // Next send should wrap to 1.
      await sync.sendSync();
      expect(adapter.sent.last.data[0], equals(1));
    });

    test('resetCounter restarts from 1 on next send', () async {
      await sync.sendSync(); // counter = 1
      await sync.sendSync(); // counter = 2
      sync.resetCounter();
      await sync.sendSync(); // counter = 1 again
      expect(adapter.sent.last.data[0], equals(1));
    });
  });

  // ── setSyncCounterEnabled ─────────────────────────────────────────────────

  group('setSyncCounterEnabled', () {
    test('enabling mid-session starts counter after current position',
        () async {
      await sync.sendSync(); // no counter
      sync.setSyncCounterEnabled(true);
      await sync.sendSync(); // counter = 1
      expect(adapter.sent[1].data, equals([1]));
    });

    test('disabling reverts to 0-byte frames', () async {
      sync.setSyncCounterEnabled(true);
      await sync.sendSync(); // [0x01]
      sync.setSyncCounterEnabled(false);
      await sync.sendSync(); // 0-byte
      expect(adapter.sent[1].data, isEmpty);
    });
  });

  // ── Incoming SYNC callbacks ───────────────────────────────────────────────

  group('registerSyncCallback', () {
    test('fires callback on incoming SYNC frame with counter byte', () async {
      int? received;
      sync.registerSyncCallback((c) => received = c);

      adapter.inject(CanMessage(cobId: 0x080, data: Uint8List.fromList([5])));
      await Future<void>.delayed(Duration.zero);

      expect(received, equals(5));
    });

    test('passes null when incoming SYNC frame has no data byte', () async {
      int? received = 99;
      sync.registerSyncCallback((c) => received = c);

      adapter.inject(CanMessage(cobId: 0x080, data: Uint8List(0)));
      await Future<void>.delayed(Duration.zero);

      expect(received, isNull);
    });

    test('fires multiple registered callbacks', () async {
      final results = <int>[];
      sync.registerSyncCallback((_) => results.add(1));
      sync.registerSyncCallback((_) => results.add(2));

      adapter.inject(CanMessage(cobId: 0x080, data: Uint8List.fromList([1])));
      await Future<void>.delayed(Duration.zero);

      expect(results, equals([1, 2]));
    });

    test('ignores frames with non-SYNC COB-ID', () async {
      var fired = false;
      sync.registerSyncCallback((_) => fired = true);

      adapter.inject(CanMessage(cobId: 0x181, data: Uint8List.fromList([1])));
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });
  });

  // ── unregisterSyncCallback ────────────────────────────────────────────────

  group('unregisterSyncCallback', () {
    test('removed callback no longer fires', () async {
      var fired = false;
      void cb(int? _) => fired = true;

      sync.registerSyncCallback(cb);
      sync.unregisterSyncCallback(cb);

      adapter.inject(CanMessage(cobId: 0x080, data: Uint8List.fromList([1])));
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });

    test('only the unregistered callback is removed', () async {
      final results = <int>[];
      void cb1(int? _) => results.add(1);
      void cb2(int? _) => results.add(2);

      sync.registerSyncCallback(cb1);
      sync.registerSyncCallback(cb2);
      sync.unregisterSyncCallback(cb1);

      adapter.inject(CanMessage(cobId: 0x080, data: Uint8List.fromList([1])));
      await Future<void>.delayed(Duration.zero);

      expect(results, equals([2]));
    });
  });
}
