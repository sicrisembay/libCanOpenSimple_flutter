/// Unit tests for LssClient — Phase 7 (switch & inquire services).
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

  /// If set, injects one response for each outgoing frame.
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

// ── Frame helpers ─────────────────────────────────────────────────────────────

/// Builds an 8-byte LSS response frame with [cs] and 4-byte LE [value].
CanMessage lssResponse(int cs, [int value = 0]) {
  final data = Uint8List(8);
  data[0] = cs;
  data[1] = value & 0xFF;
  data[2] = (value >> 8) & 0xFF;
  data[3] = (value >> 16) & 0xFF;
  data[4] = (value >> 24) & 0xFF;
  return CanMessage(cobId: CobId.lss, data: data);
}

/// Builds the selective-switch confirmation response (cs = 0x44).
CanMessage selectiveResponse() => lssResponse(lssCsSwitchSelectiveResponse);

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  late FakeCanAdapter adapter;
  late LssClient lss;

  setUp(() {
    adapter = FakeCanAdapter();
    lss = LssClient(adapter);
  });

  tearDown(() {
    lss.dispose();
    adapter.dispose();
  });

  // ── lssSwitchStateGlobal ──────────────────────────────────────────────────

  group('lssSwitchStateGlobal', () {
    test('sends correct frame for configuration mode', () async {
      await lss.lssSwitchStateGlobal(LssMode.configuration);

      expect(adapter.sent, hasLength(1));
      expect(adapter.sent[0].cobId, equals(CobId.lssMaster));
      expect(adapter.sent[0].data,
          equals([0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]));
    });

    test('sends correct frame for operation mode', () async {
      await lss.lssSwitchStateGlobal(LssMode.operation);

      expect(adapter.sent[0].data,
          equals([0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]));
    });

    test('sends on COB-ID 0x7E5', () async {
      await lss.lssSwitchStateGlobal(LssMode.configuration);
      expect(adapter.sent[0].cobId, equals(0x7E5));
    });
  });

  // ── lssSwitchStateSelective ───────────────────────────────────────────────

  group('lssSwitchStateSelective', () {
    const address = LssAddress(
      vendorId: 0x00000001,
      productCode: 0x00000002,
      revisionNumber: 0x00000003,
      serialNumber: 0x00000004,
    );

    test('sends four identification frames with correct cs bytes', () async {
      adapter.autoReplyWith = (_) => selectiveResponse();

      await lss.lssSwitchStateSelective(address);

      expect(adapter.sent, hasLength(4));
      expect(adapter.sent[0].data[0], equals(lssCsSwitchSelectiveVendor));
      expect(adapter.sent[1].data[0], equals(lssCsSwitchSelectiveProduct));
      expect(adapter.sent[2].data[0], equals(lssCsSwitchSelectiveRevision));
      expect(adapter.sent[3].data[0], equals(lssCsSwitchSelectiveSerial));
    });

    test('encodes vendorId as 4-byte LE in first frame', () async {
      adapter.autoReplyWith = (_) => selectiveResponse();

      const addr = LssAddress(
        vendorId: 0x12345678,
        productCode: 0,
        revisionNumber: 0,
        serialNumber: 0,
      );
      await lss.lssSwitchStateSelective(addr);

      final d = adapter.sent[0].data;
      expect(d.sublist(1, 5), equals([0x78, 0x56, 0x34, 0x12]));
    });

    test('encodes all address fields correctly', () async {
      adapter.autoReplyWith = (_) => selectiveResponse();

      const addr = LssAddress(
        vendorId: 0xAABBCCDD,
        productCode: 0x11223344,
        revisionNumber: 0x55667788,
        serialNumber: 0x99AABBCC,
      );
      await lss.lssSwitchStateSelective(addr);

      expect(
          adapter.sent[0].data.sublist(1, 5), equals([0xDD, 0xCC, 0xBB, 0xAA]));
      expect(
          adapter.sent[1].data.sublist(1, 5), equals([0x44, 0x33, 0x22, 0x11]));
      expect(
          adapter.sent[2].data.sublist(1, 5), equals([0x88, 0x77, 0x66, 0x55]));
      expect(
          adapter.sent[3].data.sublist(1, 5), equals([0xCC, 0xBB, 0xAA, 0x99]));
    });

    test('throws CanOpenTimeoutException when no response arrives', () async {
      await expectLater(
        lss.lssSwitchStateSelective(
          address,
          timeout: const Duration(milliseconds: 10),
        ),
        throwsA(isA<CanOpenTimeoutException>()),
      );
    });
  });

  // ── lssInquireVendorId ────────────────────────────────────────────────────

  group('lssInquireVendorId', () {
    test('sends correct inquiry frame (cs = 0x5A)', () async {
      adapter.autoReplyWith =
          (_) => lssResponse(lssCsInquireVendorId, 0x00001234);

      await lss.lssInquireVendorId();

      expect(adapter.sent[0].cobId, equals(CobId.lssMaster));
      expect(adapter.sent[0].data[0], equals(lssCsInquireVendorId));
      expect(adapter.sent[0].data.sublist(1), everyElement(0));
    });

    test('decodes 4-byte LE vendor ID from response', () async {
      adapter.autoReplyWith =
          (_) => lssResponse(lssCsInquireVendorId, 0xDEADBEEF);

      final result = await lss.lssInquireVendorId();

      expect(result, equals(0xDEADBEEF));
    });

    test('throws CanOpenTimeoutException when no response', () async {
      await expectLater(
        lss.lssInquireVendorId(timeout: const Duration(milliseconds: 10)),
        throwsA(isA<CanOpenTimeoutException>()),
      );
    });
  });

  // ── lssInquireProductCode ─────────────────────────────────────────────────

  group('lssInquireProductCode', () {
    test('sends cs = 0x5B and decodes response', () async {
      adapter.autoReplyWith =
          (_) => lssResponse(lssCsInquireProductCode, 0x00005678);

      final result = await lss.lssInquireProductCode();

      expect(adapter.sent[0].data[0], equals(lssCsInquireProductCode));
      expect(result, equals(0x00005678));
    });
  });

  // ── lssInquireRevisionNumber ──────────────────────────────────────────────

  group('lssInquireRevisionNumber', () {
    test('sends cs = 0x5C and decodes response', () async {
      adapter.autoReplyWith =
          (_) => lssResponse(lssCsInquireRevisionNumber, 0xABCD1234);

      final result = await lss.lssInquireRevisionNumber();

      expect(adapter.sent[0].data[0], equals(lssCsInquireRevisionNumber));
      expect(result, equals(0xABCD1234));
    });
  });

  // ── lssInquireSerialNumber ────────────────────────────────────────────────

  group('lssInquireSerialNumber', () {
    test('sends cs = 0x5D and decodes response', () async {
      adapter.autoReplyWith =
          (_) => lssResponse(lssCsInquireSerialNumber, 0x0000FFFF);

      final result = await lss.lssInquireSerialNumber();

      expect(adapter.sent[0].data[0], equals(lssCsInquireSerialNumber));
      expect(result, equals(0x0000FFFF));
    });

    test('throws CanOpenTimeoutException when no response', () async {
      await expectLater(
        lss.lssInquireSerialNumber(timeout: const Duration(milliseconds: 10)),
        throwsA(isA<CanOpenTimeoutException>()),
      );
    });
  });

  // ── Multi-response inquire ────────────────────────────────────────────────

  group('lssInquireSerialNumbers (multi-response)', () {
    test('collects two responses within timeout window', () async {
      // Inject two responses as microtasks after the request is sent.
      unawaited(Future.microtask(() {
        adapter.inject(lssResponse(lssCsInquireSerialNumber, 0xAABBCCDD));
        adapter.inject(lssResponse(lssCsInquireSerialNumber, 0x11223344));
      }));

      final serials = await lss.lssInquireSerialNumbers(
        timeout: const Duration(milliseconds: 50),
      );

      expect(serials, equals([0xAABBCCDD, 0x11223344]));
    });

    test('returns empty list when no responses arrive', () async {
      final serials = await lss.lssInquireSerialNumbers(
        timeout: const Duration(milliseconds: 10),
      );

      expect(serials, isEmpty);
    });

    test('filters out responses with wrong cs byte', () async {
      unawaited(Future.microtask(() {
        // Wrong cs (product code response, not serial number).
        adapter.inject(lssResponse(lssCsInquireProductCode, 0xFFFF0000));
        adapter.inject(lssResponse(lssCsInquireSerialNumber, 0x12345678));
      }));

      final serials = await lss.lssInquireSerialNumbers(
        timeout: const Duration(milliseconds: 50),
      );

      expect(serials, equals([0x12345678]));
    });
  });

  group('lssInquireVendorIds (multi-response)', () {
    test('collects two vendor IDs', () async {
      unawaited(Future.microtask(() {
        adapter.inject(lssResponse(lssCsInquireVendorId, 0x00000001));
        adapter.inject(lssResponse(lssCsInquireVendorId, 0x00000002));
      }));

      final vendors = await lss.lssInquireVendorIds(
        timeout: const Duration(milliseconds: 50),
      );

      expect(vendors, equals([0x00000001, 0x00000002]));
    });
  });
}
