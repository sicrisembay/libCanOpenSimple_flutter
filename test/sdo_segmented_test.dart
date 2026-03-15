/// Tests for SDO segmented transfers (Phase 4):
/// - Segmented upload  (sdoRead  returning > 4 bytes)
/// - Segmented download (sdoWrite sending > 4 bytes)
/// - 64-bit float helpers (sdoReadF64 / sdoWriteF64)
/// - String read via segmented transfer
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:canopen_client/canopen_client.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Fake adapter (shared with sdo_test.dart — copied to stay self-contained) ─

class FakeCanAdapter implements ICanAdapter {
  final StreamController<CanMessage> _rxCtrl =
      StreamController<CanMessage>.broadcast();

  final List<CanMessage> sent = [];

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
    }
  }

  @override
  void dispose() => _rxCtrl.close();

  void inject(CanMessage message) => _rxCtrl.add(message);
}

// ── Frame builder helpers ─────────────────────────────────────────────────────

/// Builds a segmented upload initiate response.
///
/// [sFlag] — whether byte size is included in [4..7].
/// [size]  — total data size (written LE into bytes [4..7] when [sFlag]=true).
CanMessage uploadSegmentedInitiate(
  int nodeId, {
  bool sFlag = false,
  int size = 0,
}) {
  final frame = Uint8List(8);
  // cs=010 (upload), e=0, s=sFlag → 0x40 | sFlag
  frame[0] = 0x40 | (sFlag ? 0x01 : 0x00);
  if (sFlag) {
    frame[4] = size & 0xFF;
    frame[5] = (size >> 8) & 0xFF;
    frame[6] = (size >> 16) & 0xFF;
    frame[7] = (size >> 24) & 0xFF;
  }
  return CanMessage(cobId: CobId.sdoTxBase + nodeId, data: frame);
}

/// Builds a segmented upload segment response.
///
/// [toggle] — toggle bit (0 or 1).
/// [n]      — number of unused bytes at the end of the 7-byte payload (0–7).
/// [c]      — 1 = last segment.
/// [data]   — actual segment bytes (length must equal 7 − [n]).
CanMessage uploadSegmentResp(
  int nodeId, {
  required int toggle,
  required int n,
  required int c,
  required List<int> data,
}) {
  assert(data.length == 7 - n);
  final frame = Uint8List(8);
  frame[0] = (toggle << 4) | (n << 1) | c;
  for (var i = 0; i < data.length; i++) {
    frame[1 + i] = data[i];
  }
  return CanMessage(cobId: CobId.sdoTxBase + nodeId, data: frame);
}

/// Builds a segmented download initiate ACK (same frame layout as expedited
/// download ACK — cs=011).
CanMessage downloadInitiateAck(int nodeId) {
  final frame = Uint8List(8);
  frame[0] = 0x60;
  return CanMessage(cobId: CobId.sdoTxBase + nodeId, data: frame);
}

/// Builds a segmented download segment ACK.
///
/// [toggle] — toggle bit (0 or 1) echoed back.
CanMessage downloadSegmentAck(int nodeId, int toggle) {
  final frame = Uint8List(8);
  frame[0] = 0x20 | (toggle << 4);
  return CanMessage(cobId: CobId.sdoTxBase + nodeId, data: frame);
}

/// Builds an SDO abort response.
CanMessage abortResponse(int nodeId, int abortCode) {
  final frame = Uint8List(8);
  frame[0] = 0x80;
  final bd = ByteData(4)..setUint32(0, abortCode, Endian.little);
  frame.setRange(4, 8, bd.buffer.asUint8List());
  return CanMessage(cobId: CobId.sdoTxBase + nodeId, data: frame);
}

// ── Response-queue helper ─────────────────────────────────────────────────────

/// Returns a stateful [autoReplyWith] callback that returns each entry from
/// [responses] in sequence, regardless of the incoming request.
CanMessage Function(CanMessage) responseQueue(List<CanMessage> responses) {
  var index = 0;
  return (_) {
    if (index >= responses.length) {
      throw StateError('ResponseQueue exhausted (${responses.length} entries)');
    }
    return responses[index++];
  };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  const nodeId = 5;
  const index = 0x2100;
  const subIndex = 0;

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

  // ── Segmented upload ────────────────────────────────────────────────────────

  group('Segmented upload', () {
    test('assembles bytes from two segments (8 bytes, s=1)', () async {
      // Segment 0: 7 bytes [1..7], toggle=0, c=0
      // Segment 1: 1 byte  [8],    toggle=1, c=1 (n=6 unused)
      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId, sFlag: true, size: 8),
        uploadSegmentResp(nodeId,
            toggle: 0, n: 0, c: 0, data: [1, 2, 3, 4, 5, 6, 7]),
        uploadSegmentResp(nodeId, toggle: 1, n: 6, c: 1, data: [8]),
      ]);

      final result = await sdo.sdoRead(nodeId, index, subIndex);

      expect(result, equals([1, 2, 3, 4, 5, 6, 7, 8]));
    });

    test('assembles bytes from single max-size segment (7 bytes)', () async {
      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId, sFlag: true, size: 7),
        uploadSegmentResp(nodeId,
            toggle: 0, n: 0, c: 1, data: [10, 20, 30, 40, 50, 60, 70]),
      ]);

      final result = await sdo.sdoRead(nodeId, index, subIndex);

      expect(result, equals([10, 20, 30, 40, 50, 60, 70]));
    });

    test('assembles bytes across three segments (15 bytes, no size flag)',
        () async {
      // 15 bytes = 7 + 7 + 1
      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId, sFlag: false), // no size indicated
        uploadSegmentResp(nodeId,
            toggle: 0, n: 0, c: 0, data: [1, 2, 3, 4, 5, 6, 7]),
        uploadSegmentResp(nodeId,
            toggle: 1, n: 0, c: 0, data: [8, 9, 10, 11, 12, 13, 14]),
        uploadSegmentResp(nodeId, toggle: 0, n: 6, c: 1, data: [15]),
      ]);

      final result = await sdo.sdoRead(nodeId, index, subIndex);

      expect(result, equals(List.generate(15, (i) => i + 1)));
    });

    test('sends correct upload segment request bytes', () async {
      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId),
        uploadSegmentResp(nodeId,
            toggle: 0, n: 0, c: 1, data: [42, 43, 44, 45, 46, 47, 48]),
      ]);

      await sdo.sdoRead(nodeId, index, subIndex);

      // sent[0]: upload initiate request (0x40)
      expect(adapter.sent[0].data[0], equals(0x40));
      // sent[1]: first upload segment request — cs=011, toggle=0 → 0x60
      expect(adapter.sent[1].data[0], equals(0x60));
      expect(adapter.sent[1].data.sublist(1), everyElement(0));
    });

    test('alternates toggle bits in segment requests', () async {
      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId),
        uploadSegmentResp(nodeId,
            toggle: 0, n: 0, c: 0, data: [1, 2, 3, 4, 5, 6, 7]),
        uploadSegmentResp(nodeId, toggle: 1, n: 6, c: 1, data: [8]),
      ]);

      await sdo.sdoRead(nodeId, index, subIndex);

      // sent[1]: toggle=0 → byte[0] = 0x60
      expect(adapter.sent[1].data[0], equals(0x60));
      // sent[2]: toggle=1 → byte[0] = 0x60 | (1<<4) = 0x70
      expect(adapter.sent[2].data[0], equals(0x70));
    });

    test('throws CanOpenException on toggle mismatch in segment response',
        () async {
      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId),
        // Wrong toggle (1 instead of expected 0)
        uploadSegmentResp(nodeId,
            toggle: 1, n: 0, c: 1, data: [1, 2, 3, 4, 5, 6, 7]),
      ]);

      await expectLater(
        sdo.sdoRead(nodeId, index, subIndex),
        throwsA(isA<CanOpenException>()),
      );
    });

    test('throws SdoAbortException on abort during segment loop', () async {
      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId),
        abortResponse(nodeId, 0x06090011), // object does not exist
      ]);

      await expectLater(
        sdo.sdoRead(nodeId, index, subIndex),
        throwsA(
          isA<SdoAbortException>().having(
            (e) => e.abortCode,
            'abortCode',
            0x06090011,
          ),
        ),
      );
    });

    test('throws CanOpenException on unexpected segment cs byte', () async {
      final badFrame = Uint8List(8);
      badFrame[0] = 0x80; // abort — but with no abort code structure
      // Craft an unexpected cs by using 0x40..0x5F range (cs=010)
      badFrame[0] = 0x40;

      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId),
        CanMessage(cobId: CobId.sdoTxBase + nodeId, data: badFrame),
      ]);

      await expectLater(
        sdo.sdoRead(nodeId, index, subIndex),
        throwsA(isA<CanOpenException>()),
      );
    });
  });

  // ── Segmented download ──────────────────────────────────────────────────────

  group('Segmented download', () {
    test('sends correct initiate frame for 5-byte data', () async {
      adapter.autoReplyWith = responseQueue([
        downloadInitiateAck(nodeId),
        downloadSegmentAck(nodeId, 0),
      ]);

      await sdo.sdoWrite(
          nodeId, index, subIndex, Uint8List.fromList([1, 2, 3, 4, 5]));

      final init = adapter.sent[0].data;
      expect(init[0], equals(0x21)); // cs=001, e=0, s=1
      expect(init[1], equals(index & 0xFF));
      expect(init[2], equals((index >> 8) & 0xFF));
      expect(init[3], equals(subIndex));
      expect(init[4], equals(5)); // size LE
      expect(init[5], equals(0));
      expect(init[6], equals(0));
      expect(init[7], equals(0));
    });

    test('sends correct segment frame for 5-byte payload', () async {
      adapter.autoReplyWith = responseQueue([
        downloadInitiateAck(nodeId),
        downloadSegmentAck(nodeId, 0),
      ]);

      await sdo.sdoWrite(
          nodeId, index, subIndex, Uint8List.fromList([1, 2, 3, 4, 5]));

      final seg = adapter.sent[1].data;
      // n = 7-5 = 2, c=1, toggle=0 → (0<<4)|(2<<1)|1 = 5
      expect(seg[0], equals(0x05));
      expect(seg.sublist(1, 6), equals([1, 2, 3, 4, 5]));
    });

    test('sends correct frames for 15-byte data (3 segments)', () async {
      adapter.autoReplyWith = responseQueue([
        downloadInitiateAck(nodeId),
        downloadSegmentAck(nodeId, 0), // seg 0: toggle=0
        downloadSegmentAck(nodeId, 1), // seg 1: toggle=1
        downloadSegmentAck(nodeId, 0), // seg 2: toggle=0
      ]);

      final data = Uint8List.fromList(List.generate(15, (i) => i + 1));
      await sdo.sdoWrite(nodeId, index, subIndex, data);

      // Initiate frame check.
      expect(adapter.sent[0].data[0], equals(0x21));
      expect(adapter.sent[0].data[4], equals(15));

      // Segment 0: n=0, c=0, toggle=0 → byte[0]=0x00
      expect(adapter.sent[1].data[0], equals(0x00));
      expect(adapter.sent[1].data.sublist(1, 8), equals([1, 2, 3, 4, 5, 6, 7]));

      // Segment 1: n=0, c=0, toggle=1 → byte[0]=0x10
      expect(adapter.sent[2].data[0], equals(0x10));
      expect(adapter.sent[2].data.sublist(1, 8),
          equals([8, 9, 10, 11, 12, 13, 14]));

      // Segment 2: n=6, c=1, toggle=0 → byte[0]=(6<<1)|1 = 13 = 0x0D
      expect(adapter.sent[3].data[0], equals(0x0D));
      expect(adapter.sent[3].data[1], equals(15));
    });

    test('throws SdoAbortException on abort during initiate', () async {
      adapter.autoReplyWith = responseQueue([
        abortResponse(nodeId, 0x05030000), // toggle bit not alternated
      ]);

      await expectLater(
        sdo.sdoWrite(
            nodeId, index, subIndex, Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsA(
          isA<SdoAbortException>().having(
            (e) => e.abortCode,
            'abortCode',
            0x05030000,
          ),
        ),
      );
    });

    test('throws SdoAbortException on abort during segment loop', () async {
      adapter.autoReplyWith = responseQueue([
        downloadInitiateAck(nodeId),
        abortResponse(nodeId, 0x08000020), // data cannot be transferred
      ]);

      await expectLater(
        sdo.sdoWrite(
            nodeId, index, subIndex, Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsA(isA<SdoAbortException>()),
      );
    });

    test('throws CanOpenException on download segment toggle mismatch',
        () async {
      adapter.autoReplyWith = responseQueue([
        downloadInitiateAck(nodeId),
        downloadSegmentAck(nodeId, 1), // wrong: expected toggle=0
      ]);

      await expectLater(
        sdo.sdoWrite(
            nodeId, index, subIndex, Uint8List.fromList([1, 2, 3, 4, 5])),
        throwsA(isA<CanOpenException>()),
      );
    });

    test('throws CanOpenException when data is empty', () {
      expect(
        () => sdo.sdoWrite(nodeId, index, subIndex, Uint8List(0)),
        throwsA(isA<CanOpenException>()),
      );
    });
  });

  // ── F64 helpers ─────────────────────────────────────────────────────────────

  group('F64 helpers', () {
    test('sdoWriteF64 sends 8 bytes via segmented transfer', () async {
      adapter.autoReplyWith = responseQueue([
        downloadInitiateAck(nodeId),
        downloadSegmentAck(nodeId, 0),
        downloadSegmentAck(nodeId, 1),
      ]);

      await sdo.sdoWriteF64(nodeId, index, subIndex, 3.14159265358979);

      // Initiate must declare 8 bytes.
      expect(adapter.sent[0].data[4], equals(8));
      // Two segments: first 7 bytes, then 1 byte.
      expect(adapter.sent.length, equals(3)); // initiate + 2 segments
    });

    test('sdoReadF64 decodes 64-bit double via segmented transfer', () async {
      // Encode Pi as IEEE 754 double LE
      final bd = ByteData(8)..setFloat64(0, 3.14, Endian.little);
      final bytes = bd.buffer.asUint8List();

      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId, sFlag: true, size: 8),
        uploadSegmentResp(nodeId,
            toggle: 0, n: 0, c: 0, data: bytes.sublist(0, 7).toList()),
        uploadSegmentResp(nodeId, toggle: 1, n: 6, c: 1, data: [bytes[7]]),
      ]);

      final result = await sdo.sdoReadF64(nodeId, index, subIndex);

      expect(result, closeTo(3.14, 1e-10));
    });
  });

  // ── String via segmented ────────────────────────────────────────────────────

  group('String read via segmented', () {
    test('sdoReadString returns correct UTF-8 string across segments',
        () async {
      // "Hello!" = 6 bytes (fits in one segment with n=1 unused)
      const text = 'Hello!';
      final bytes = text.codeUnits;

      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId, sFlag: true, size: bytes.length),
        uploadSegmentResp(nodeId, toggle: 0, n: 1, c: 1, data: bytes.toList()),
      ]);

      final result = await sdo.sdoReadString(nodeId, index, subIndex);

      expect(result, equals(text));
    });

    test('sdoReadString decodes a 13-byte string across two segments',
        () async {
      // "Hello, World!" = 13 bytes → seg0: 7 bytes, seg1: 6 bytes (n=1)
      const text = 'Hello, World!';
      final bytes = text.codeUnits;

      adapter.autoReplyWith = responseQueue([
        uploadSegmentedInitiate(nodeId, sFlag: true, size: bytes.length),
        uploadSegmentResp(nodeId,
            toggle: 0, n: 0, c: 0, data: bytes.sublist(0, 7).toList()),
        uploadSegmentResp(nodeId,
            toggle: 1, n: 1, c: 1, data: bytes.sublist(7).toList()),
      ]);

      final result = await sdo.sdoReadString(nodeId, index, subIndex);

      expect(result, equals(text));
    });
  });
}
