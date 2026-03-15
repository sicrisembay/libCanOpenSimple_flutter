import 'dart:async';
import 'dart:typed_data';

import 'package:canopen_client/canopen_client.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Fake adapter ─────────────────────────────────────────────────────────────

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

  /// Injects a fake received frame into the rx stream.
  void inject(CanMessage message) => _rxCtrl.add(message);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

CanMessage heartbeatFrame(int nodeId, int stateByte) => CanMessage(
      cobId: CobId.heartbeatBase + nodeId,
      data: Uint8List.fromList([stateByte]),
    );

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late FakeCanAdapter adapter;
  late NmtManager nmt;

  setUp(() {
    adapter = FakeCanAdapter();
    nmt = NmtManager(adapter);
  });

  tearDown(() {
    nmt.dispose();
    adapter.dispose();
  });

  // ── NMT command framing ──────────────────────────────────────────────────

  group('NMT command framing', () {
    test('nmtStart sends [0x01, nodeId] on COB-ID 0x000', () async {
      await nmt.nmtStart(5);
      expect(adapter.sent.length, 1);
      expect(adapter.sent.first.cobId, 0x000);
      expect(adapter.sent.first.data, [0x01, 0x05]);
    });

    test('nmtStop sends [0x02, nodeId] on COB-ID 0x000', () async {
      await nmt.nmtStop(3);
      expect(adapter.sent.first.cobId, 0x000);
      expect(adapter.sent.first.data, [0x02, 0x03]);
    });

    test('nmtEnterPreOperational sends [0x80, nodeId]', () async {
      await nmt.nmtEnterPreOperational(10);
      expect(adapter.sent.first.data, [0x80, 0x0A]);
    });

    test('nmtResetNode sends [0x81, nodeId]', () async {
      await nmt.nmtResetNode(7);
      expect(adapter.sent.first.data, [0x81, 0x07]);
    });

    test('nmtResetCommunication sends [0x82, nodeId]', () async {
      await nmt.nmtResetCommunication(7);
      expect(adapter.sent.first.data, [0x82, 0x07]);
    });

    test('broadcast (nodeId=0) sends [cmd, 0x00]', () async {
      await nmt.nmtStart(0);
      expect(adapter.sent.first.data, [0x01, 0x00]);
    });
  });

  // ── Heartbeat reception ──────────────────────────────────────────────────

  group('Heartbeat reception', () {
    test('updates node state on heartbeat frame', () async {
      adapter.inject(heartbeatFrame(5, 0x05)); // operational
      await Future<void>.delayed(Duration.zero);
      expect(nmt.getNodeState(5), NmtState.operational);
    });

    test('parses pre-operational state byte 0x7F', () async {
      adapter.inject(heartbeatFrame(3, 0x7F));
      await Future<void>.delayed(Duration.zero);
      expect(nmt.getNodeState(3), NmtState.preOperational);
    });

    test('parses stopped state byte 0x04', () async {
      adapter.inject(heartbeatFrame(1, 0x04));
      await Future<void>.delayed(Duration.zero);
      expect(nmt.getNodeState(1), NmtState.stopped);
    });

    test('parses boot-up state byte 0x00', () async {
      adapter.inject(heartbeatFrame(2, 0x00));
      await Future<void>.delayed(Duration.zero);
      expect(nmt.getNodeState(2), NmtState.bootUp);
    });

    test('getNodeState returns unknown for unseen node', () {
      expect(nmt.getNodeState(99), NmtState.unknown);
    });

    test('ignores frames outside 0x701–0x77F range', () async {
      adapter
          .inject(CanMessage(cobId: 0x080, data: Uint8List.fromList([0x05])));
      await Future<void>.delayed(Duration.zero);
      expect(nmt.getNodeState(0), NmtState.unknown);
    });

    test('ignores heartbeat frames with empty data', () async {
      adapter.inject(
          CanMessage(cobId: CobId.heartbeatBase + 5, data: Uint8List(0)));
      await Future<void>.delayed(Duration.zero);
      expect(nmt.getNodeState(5), NmtState.unknown);
    });
  });

  // ── Heartbeat callbacks ──────────────────────────────────────────────────

  group('Heartbeat callbacks', () {
    test('registered callback fires with correct nodeId and state', () async {
      int? cbNodeId;
      NmtState? cbState;

      nmt.registerHeartbeatCallback(5, (id, state) {
        cbNodeId = id;
        cbState = state;
      });

      adapter.inject(heartbeatFrame(5, 0x05));
      await Future<void>.delayed(Duration.zero);

      expect(cbNodeId, 5);
      expect(cbState, NmtState.operational);
    });

    test('callback fires on every state change', () async {
      final states = <NmtState>[];
      nmt.registerHeartbeatCallback(5, (_, s) => states.add(s));

      adapter.inject(heartbeatFrame(5, 0x7F)); // pre-op
      adapter.inject(heartbeatFrame(5, 0x05)); // operational
      adapter.inject(heartbeatFrame(5, 0x04)); // stopped
      await Future<void>.delayed(Duration.zero);

      expect(states, [
        NmtState.preOperational,
        NmtState.operational,
        NmtState.stopped,
      ]);
    });

    test('unregistered callback does not fire', () async {
      var fired = false;
      nmt.registerHeartbeatCallback(5, (_, __) => fired = true);
      nmt.unregisterHeartbeatCallback(5);

      adapter.inject(heartbeatFrame(5, 0x05));
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });

    test('registering a new callback replaces the old one', () async {
      var firstFired = false;
      var secondFired = false;

      nmt.registerHeartbeatCallback(5, (_, __) => firstFired = true);
      nmt.registerHeartbeatCallback(5, (_, __) => secondFired = true);

      adapter.inject(heartbeatFrame(5, 0x05));
      await Future<void>.delayed(Duration.zero);

      expect(firstFired, isFalse);
      expect(secondFired, isTrue);
    });

    test('callback for node A does not fire for node B heartbeat', () async {
      var fired = false;
      nmt.registerHeartbeatCallback(5, (_, __) => fired = true);

      adapter.inject(heartbeatFrame(6, 0x05)); // different node
      await Future<void>.delayed(Duration.zero);

      expect(fired, isFalse);
    });
  });

  // ── Dispose ──────────────────────────────────────────────────────────────

  group('dispose', () {
    test('dispose cancels rx subscription without throwing', () {
      expect(nmt.dispose, returnsNormally);
    });

    test('state is cleared after dispose', () async {
      adapter.inject(heartbeatFrame(5, 0x05));
      await Future<void>.delayed(Duration.zero);
      expect(nmt.getNodeState(5), NmtState.operational);

      nmt.dispose();
      // After dispose the internal map is cleared.
      expect(nmt.getNodeState(5), NmtState.unknown);
    });
  });
}
