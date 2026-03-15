import 'dart:async';
import 'dart:typed_data';

import 'package:canopen_client/canopen_client.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Fake adapter ──────────────────────────────────────────────────────────────

class FakeCanAdapter implements ICanAdapter {
  final StreamController<CanMessage> _rxCtrl =
      StreamController<CanMessage>.broadcast();

  final List<CanMessage> sent = [];

  /// If set, every call to [send] also injects this response after a microtask.
  CanMessage? autoResponse;

  /// If set, generates a response per request — takes priority over [autoResponse].
  CanMessage Function(CanMessage request)? autoReplyWith;

  @override
  Stream<CanMessage> get rxFrames => _rxCtrl.stream;

  @override
  Future<List<String>> listPorts() async => [];

  @override
  Future<void> connect(String port, BusSpeed speed) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> send(CanMessage message) async {
    sent.add(message);
    if (autoReplyWith != null) {
      final resp = autoReplyWith!(message);
      scheduleMicrotask(() => _rxCtrl.add(resp));
    } else if (autoResponse != null) {
      final resp = autoResponse!;
      scheduleMicrotask(() => _rxCtrl.add(resp));
    }
  }

  @override
  void dispose() => _rxCtrl.close();

  void inject(CanMessage message) => _rxCtrl.add(message);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Builds an 8-byte SDO expedited upload response from [nodeId].
///
/// [dataBytes] is 1–4 bytes to embed; the rest of [4..7] is zero-padded.
CanMessage uploadResponse(int nodeId, List<int> dataBytes) {
  assert(dataBytes.isNotEmpty && dataBytes.length <= 4);
  final n = 4 - dataBytes.length; // unused bytes
  final cmdByte = 0x43 | (n << 2); // cs=2, e=1, s=1, n=unused
  final frame = Uint8List(8);
  frame[0] = cmdByte;
  for (var i = 0; i < dataBytes.length; i++) {
    frame[4 + i] = dataBytes[i];
  }
  return CanMessage(cobId: CobId.sdoTxBase + nodeId, data: frame);
}

/// Builds an 8-byte SDO abort response from [nodeId].
CanMessage abortResponse(int nodeId, int abortCode) {
  final frame = Uint8List(8);
  frame[0] = 0x80;
  final bd = ByteData(4)..setUint32(0, abortCode, Endian.little);
  frame.setRange(4, 8, bd.buffer.asUint8List());
  return CanMessage(cobId: CobId.sdoTxBase + nodeId, data: frame);
}

/// Builds an 8-byte SDO download (write) success response from [nodeId].
CanMessage downloadResponse(int nodeId, int index, int subIndex) {
  final frame = Uint8List(8);
  frame[0] = 0x60;
  frame[1] = index & 0xFF;
  frame[2] = (index >> 8) & 0xFF;
  frame[3] = subIndex & 0xFF;
  return CanMessage(cobId: CobId.sdoTxBase + nodeId, data: frame);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late FakeCanAdapter adapter;
  late SdoClient sdo;

  setUp(() {
    adapter = FakeCanAdapter();
    sdo = SdoClient(adapter);
  });

  tearDown(() {
    sdo.dispose();
    adapter.dispose();
  });

  // ── Upload (read) request framing ─────────────────────────────────────────

  group('SDO upload request framing', () {
    test('sends correct 8-byte request on sdoRx COB-ID', () async {
      adapter.autoResponse = uploadResponse(5, [0x42]);

      await sdo.sdoReadU8(5, 0x1001, 0x00);

      expect(adapter.sent.length, 1);
      final req = adapter.sent.first;
      expect(req.cobId, CobId.sdoRxBase + 5); // 0x605
      expect(req.data.length, 8);
      expect(req.data[0], 0x40); // upload initiate request
      expect(req.data[1], 0x01); // index low
      expect(req.data[2], 0x10); // index high
      expect(req.data[3], 0x00); // sub-index
    });

    test('index and subIndex are encoded correctly', () async {
      adapter.autoResponse = uploadResponse(3, [0x01, 0x02, 0x03, 0x04]);

      await sdo.sdoRead(3, 0x2345, 0x07);

      final req = adapter.sent.first;
      expect(req.data[1], 0x45); // index low
      expect(req.data[2], 0x23); // index high
      expect(req.data[3], 0x07); // sub-index
    });
  });

  // ── Upload response parsing ───────────────────────────────────────────────

  group('SDO upload response parsing', () {
    test('reads 1-byte value correctly', () async {
      adapter.autoResponse = uploadResponse(5, [0xAB]);
      final result = await sdo.sdoReadU8(5, 0x1001, 0);
      expect(result, 0xAB);
    });

    test('reads 2-byte value correctly (little-endian)', () async {
      adapter.autoResponse = uploadResponse(5, [0xE8, 0x03]); // 1000
      final result = await sdo.sdoReadU16(5, 0x1017, 0);
      expect(result, 1000);
    });

    test('reads 4-byte value correctly', () async {
      adapter.autoResponse = uploadResponse(5, [0x78, 0x56, 0x34, 0x12]);
      final result = await sdo.sdoReadU32(5, 0x1000, 0);
      expect(result, 0x12345678);
    });

    test('reads float32 value correctly', () async {
      // 1.0f → IEEE 754 LE: [0x00, 0x00, 0x80, 0x3F]
      adapter.autoResponse = uploadResponse(5, [0x00, 0x00, 0x80, 0x3F]);
      final result = await sdo.sdoReadF32(5, 0x2000, 1);
      expect(result, closeTo(1.0, 1e-6));
    });

    test('reads raw bytes via sdoRead', () async {
      adapter.autoResponse = uploadResponse(5, [0xDE, 0xAD]);
      final result = await sdo.sdoRead(5, 0x2000, 0);
      expect(result, [0xDE, 0xAD]);
    });
  });

  // ── Download (write) request framing ─────────────────────────────────────

  group('SDO download request framing', () {
    test('sdoWriteU8 sends correct command byte 0x2F', () async {
      adapter.autoResponse = downloadResponse(5, 0x1017, 0);
      await sdo.sdoWriteU8(5, 0x1017, 0, 0xAB);

      final req = adapter.sent.first;
      expect(req.cobId, CobId.sdoRxBase + 5);
      expect(req.data[0], 0x2F); // cs=1, n=3, e=1, s=1 → 1 data byte
      expect(req.data[1], 0x17); // index low
      expect(req.data[2], 0x10); // index high
      expect(req.data[3], 0x00); // sub-index
      expect(req.data[4], 0xAB); // data
    });

    test('sdoWriteU16 sends correct command byte 0x2B and LE-encoded data',
        () async {
      adapter.autoResponse = downloadResponse(5, 0x1017, 0);
      await sdo.sdoWriteU16(5, 0x1017, 0, 1000);

      final req = adapter.sent.first;
      expect(req.data[0], 0x2B); // cs=1, n=2, e=1, s=1 → 2 data bytes
      expect(req.data[4], 0xE8); // 1000 LE low
      expect(req.data[5], 0x03); // 1000 LE high
    });

    test('sdoWriteU32 sends correct command byte 0x23', () async {
      adapter.autoResponse = downloadResponse(5, 0x1000, 0);
      await sdo.sdoWriteU32(5, 0x1000, 0, 0x12345678);

      final req = adapter.sent.first;
      expect(req.data[0], 0x23); // cs=1, n=0, e=1, s=1 → 4 data bytes
      expect(req.data[4], 0x78);
      expect(req.data[5], 0x56);
      expect(req.data[6], 0x34);
      expect(req.data[7], 0x12);
    });
  });

  // ── Abort handling ────────────────────────────────────────────────────────

  group('SDO abort handling', () {
    test('abort response on read throws SdoAbortException with correct code',
        () async {
      adapter.autoResponse = abortResponse(5, 0x06020000);

      await expectLater(
        sdo.sdoReadU32(5, 0x9999, 0),
        throwsA(
          isA<SdoAbortException>().having(
            (e) => e.abortCode,
            'abortCode',
            0x06020000,
          ),
        ),
      );
    });

    test('abort response on write throws SdoAbortException', () async {
      adapter.autoResponse = abortResponse(5, 0x06010002);

      await expectLater(
        sdo.sdoWriteU8(5, 0x1001, 0, 0x00),
        throwsA(isA<SdoAbortException>()),
      );
    });
  });

  // ── Timeout handling ──────────────────────────────────────────────────────

  group('SDO timeout handling', () {
    test('no response within timeout throws CanOpenTimeoutException', () async {
      // No autoResponse set — adapter never replies.
      await expectLater(
        sdo.sdoReadU8(
          5,
          0x1001,
          0,
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<CanOpenTimeoutException>()),
      );
    });

    test('no response on write throws CanOpenTimeoutException', () async {
      await expectLater(
        sdo.sdoWriteU8(
          5,
          0x1017,
          0,
          100,
          timeout: const Duration(milliseconds: 50),
        ),
        throwsA(isA<CanOpenTimeoutException>()),
      );
    });
  });

  // ── Concurrency serialisation ─────────────────────────────────────────────

  group('SDO concurrency serialisation', () {
    test('concurrent reads on same node all complete (serialised by lock)',
        () async {
      // autoResponse echoes the same value; we just need all 3 to complete.
      adapter.autoResponse = uploadResponse(5, [0x42]);

      final results = await Future.wait([
        sdo.sdoReadU8(5, 0x1001, 0),
        sdo.sdoReadU8(5, 0x1002, 0),
        sdo.sdoReadU8(5, 0x1003, 0),
      ]);

      expect(results, [0x42, 0x42, 0x42]);
      // 3 separate requests were sent (in serialised order).
      expect(adapter.sent.length, 3);
    });

    test('reads on different nodes do not block each other', () async {
      // autoReplyWith generates a response whose data matches the node ID.
      adapter.autoReplyWith = (req) {
        final nodeId = req.cobId - CobId.sdoRxBase;
        return uploadResponse(nodeId, [nodeId]);
      };

      final results = await Future.wait([
        sdo.sdoReadU8(1, 0x1001, 0),
        sdo.sdoReadU8(2, 0x1001, 0),
        sdo.sdoReadU8(3, 0x1001, 0),
      ]);

      expect(results[0], 1);
      expect(results[1], 2);
      expect(results[2], 3);
    });
  });
}
