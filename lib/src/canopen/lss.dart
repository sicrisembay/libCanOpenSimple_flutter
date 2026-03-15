/// LSS (Layer Setting Services) client — CiA 305.
///
/// Phase 7 implements switch-state and inquire services.
/// Phase 8 extends with configure node-ID, configure bit-timing,
/// store configuration, and Fastscan.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:synchronized/synchronized.dart';

import 'package:canopen_client/src/canopen/message.dart';
import 'package:canopen_client/src/canopen/types.dart';
import 'package:canopen_client/src/errors.dart';
import 'package:canopen_client/src/hardware/i_can_adapter.dart';
import 'package:canopen_client/src/utils.dart';

// ── LSS command-specifier constants ──────────────────────────────────────────

/// Switch State Global command specifier (master → slaves).
const int lssCsSwitchGlobal = 0x04;

/// Switch State Selective — Vendor-ID frame.
const int lssCsSwitchSelectiveVendor = 0x40;

/// Switch State Selective — Product-Code frame.
const int lssCsSwitchSelectiveProduct = 0x41;

/// Switch State Selective — Revision-Number frame.
const int lssCsSwitchSelectiveRevision = 0x42;

/// Switch State Selective — Serial-Number frame.
const int lssCsSwitchSelectiveSerial = 0x43;

/// Switch State Selective — slave confirmation response.
const int lssCsSwitchSelectiveResponse = 0x44;

/// Inquire Identity Vendor-ID (request & response share cs byte).
const int lssCsInquireVendorId = 0x5A;

/// Inquire Identity Product-Code.
const int lssCsInquireProductCode = 0x5B;

/// Inquire Identity Revision-Number.
const int lssCsInquireRevisionNumber = 0x5C;

/// Inquire Identity Serial-Number.
const int lssCsInquireSerialNumber = 0x5D;

/// Identify Slave response cs byte.
const int lssCsIdentifySlave = 0x4F;

/// Identify Non-Configured Slave response cs byte.
const int lssCsIdentifyNonConfigured = 0x50;

// ── LssAddress ────────────────────────────────────────────────────────────────

/// A 128-bit LSS address uniquely identifies a CANopen device.
///
/// Composed of four 32-bit fields from the device identity object (0x1018).
class LssAddress {
  /// Creates an [LssAddress].
  const LssAddress({
    required this.vendorId,
    required this.productCode,
    required this.revisionNumber,
    required this.serialNumber,
  });

  /// Vendor-ID (object 0x1018 sub-1).
  final int vendorId;

  /// Product-Code (object 0x1018 sub-2).
  final int productCode;

  /// Revision-Number (object 0x1018 sub-3).
  final int revisionNumber;

  /// Serial-Number (object 0x1018 sub-4).
  final int serialNumber;

  @override
  String toString() =>
      'LssAddress(vendor=0x${vendorId.toRadixString(16).toUpperCase().padLeft(8, '0')}, '
      'product=0x${productCode.toRadixString(16).toUpperCase().padLeft(8, '0')}, '
      'revision=0x${revisionNumber.toRadixString(16).toUpperCase().padLeft(8, '0')}, '
      'serial=0x${serialNumber.toRadixString(16).toUpperCase().padLeft(8, '0')})';
}

// ── LssClient ─────────────────────────────────────────────────────────────────

/// CANopen LSS client.
///
/// Provides switch-state services (global and selective) and inquire services
/// for reading the identity fields of a device currently in configuration mode.
///
/// All operations are serialised with a [Lock] to prevent overlapping LSS
/// transactions.
///
/// ## Usage
/// ```dart
/// final lss = LssClient(adapter);
///
/// // Put all slaves into configuration mode.
/// await lss.lssSwitchStateGlobal(LssMode.configuration);
///
/// // Read the vendor ID of the selected slave.
/// final vendorId = await lss.lssInquireVendorId();
///
/// // Return to operational mode.
/// await lss.lssSwitchStateGlobal(LssMode.operation);
///
/// lss.dispose();
/// ```
class LssClient {
  /// Creates an [LssClient] using [adapter] for CAN communication.
  LssClient(this._adapter);

  final ICanAdapter _adapter;
  final Lock _lock = Lock();

  // ── Switch State ──────────────────────────────────────────────────────────

  /// Switches all LSS slaves to [mode] simultaneously (global switch).
  ///
  /// No response is expected from slaves; the command is fire-and-forget.
  Future<void> lssSwitchStateGlobal(
    LssMode mode, {
    Duration timeout = const Duration(milliseconds: 100),
  }) {
    return _lock.synchronized(() async {
      final frame = _buildFrame(lssCsSwitchGlobal, [mode.byte]);
      await _adapter.send(CanMessage(cobId: CobId.lssMaster, data: frame));
    });
  }

  /// Switches a single LSS slave identified by [address] into configuration
  /// mode (selective switch).
  ///
  /// Sends four consecutive identification frames and awaits the slave's
  /// confirmation response (cs = 0x44).
  ///
  /// Throws [CanOpenTimeoutException] if no response arrives within [timeout].
  Future<void> lssSwitchStateSelective(
    LssAddress address, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    return _lock.synchronized(() async {
      await _transactSelective(address, timeout: timeout);
    });
  }

  // ── Inquire (single response) ─────────────────────────────────────────────

  /// Reads the Vendor-ID from the selected LSS slave.
  ///
  /// The slave must already be in configuration mode.
  ///
  /// Throws [CanOpenTimeoutException] if no response arrives within [timeout].
  Future<int> lssInquireVendorId({
    Duration timeout = const Duration(seconds: 1),
  }) =>
      _inquire(lssCsInquireVendorId, timeout: timeout);

  /// Reads the Product-Code from the selected LSS slave.
  Future<int> lssInquireProductCode({
    Duration timeout = const Duration(seconds: 1),
  }) =>
      _inquire(lssCsInquireProductCode, timeout: timeout);

  /// Reads the Revision-Number from the selected LSS slave.
  Future<int> lssInquireRevisionNumber({
    Duration timeout = const Duration(seconds: 1),
  }) =>
      _inquire(lssCsInquireRevisionNumber, timeout: timeout);

  /// Reads the Serial-Number from the selected LSS slave.
  Future<int> lssInquireSerialNumber({
    Duration timeout = const Duration(seconds: 1),
  }) =>
      _inquire(lssCsInquireSerialNumber, timeout: timeout);

  // ── Inquire (multi-response) ──────────────────────────────────────────────

  /// Broadcasts a Vendor-ID inquiry and collects all responses until
  /// [timeout] expires.
  ///
  /// Returns a list of Vendor-IDs received (one per responding slave).
  Future<List<int>> lssInquireVendorIds({
    Duration timeout = const Duration(seconds: 2),
  }) =>
      _inquireMulti(lssCsInquireVendorId, timeout: timeout);

  /// Broadcasts a Product-Code inquiry and collects all responses until
  /// [timeout] expires.
  Future<List<int>> lssInquireProductCodes({
    Duration timeout = const Duration(seconds: 2),
  }) =>
      _inquireMulti(lssCsInquireProductCode, timeout: timeout);

  /// Broadcasts a Revision-Number inquiry and collects all responses until
  /// [timeout] expires.
  Future<List<int>> lssInquireRevisionNumbers({
    Duration timeout = const Duration(seconds: 2),
  }) =>
      _inquireMulti(lssCsInquireRevisionNumber, timeout: timeout);

  /// Broadcasts a Serial-Number inquiry and collects all responses until
  /// [timeout] expires.
  Future<List<int>> lssInquireSerialNumbers({
    Duration timeout = const Duration(seconds: 2),
  }) =>
      _inquireMulti(lssCsInquireSerialNumber, timeout: timeout);

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Releases resources.
  void dispose() {
    // No persistent subscription — each transaction creates its own.
  }

  // ── Private ───────────────────────────────────────────────────────────────

  /// Sends [request] on COB-ID 0x7E5 and awaits a response on 0x7E4 whose
  /// first byte equals [expectedCs].
  Future<Uint8List> _transact(
    Uint8List request,
    int expectedCs, {
    required Duration timeout,
    required String context,
  }) async {
    final completer = Completer<Uint8List>();
    StreamSubscription<CanMessage>? sub;
    sub = _adapter.rxFrames.listen((msg) {
      if (msg.cobId == CobId.lss &&
          msg.data.isNotEmpty &&
          msg.data[0] == expectedCs &&
          !completer.isCompleted) {
        completer.complete(msg.data);
        sub?.cancel();
      }
    });

    await _adapter.send(CanMessage(cobId: CobId.lssMaster, data: request));

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      await sub.cancel();
      throw CanOpenTimeoutException(context);
    }
  }

  /// Sends four Switch-State-Selective frames and awaits the slave
  /// confirmation (cs = 0x44).
  Future<void> _transactSelective(
    LssAddress address, {
    required Duration timeout,
  }) async {
    final completer = Completer<void>();
    StreamSubscription<CanMessage>? sub;

    sub = _adapter.rxFrames.listen((msg) {
      if (msg.cobId == CobId.lss &&
          msg.data.isNotEmpty &&
          msg.data[0] == lssCsSwitchSelectiveResponse &&
          !completer.isCompleted) {
        completer.complete();
        sub?.cancel();
      }
    });

    // Send four identification frames.
    await _adapter.send(CanMessage(
        cobId: CobId.lssMaster,
        data: _buildFrame(
            lssCsSwitchSelectiveVendor, encodeU32LE(address.vendorId))));
    await _adapter.send(CanMessage(
        cobId: CobId.lssMaster,
        data: _buildFrame(
            lssCsSwitchSelectiveProduct, encodeU32LE(address.productCode))));
    await _adapter.send(CanMessage(
        cobId: CobId.lssMaster,
        data: _buildFrame(lssCsSwitchSelectiveRevision,
            encodeU32LE(address.revisionNumber))));
    await _adapter.send(CanMessage(
        cobId: CobId.lssMaster,
        data: _buildFrame(
            lssCsSwitchSelectiveSerial, encodeU32LE(address.serialNumber))));

    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      await sub.cancel();
      throw const CanOpenTimeoutException('LSS switch state selective');
    }
  }

  /// Sends an inquire frame and awaits a single response.
  Future<int> _inquire(int cs, {required Duration timeout}) {
    return _lock.synchronized(() async {
      final request = _buildFrame(cs, []);
      final resp = await _transact(
        request,
        cs,
        timeout: timeout,
        context: 'LSS inquire 0x${cs.toRadixString(16)}',
      );
      if (resp.length < 5) {
        throw CanOpenException(
            'LSS inquire response too short (${resp.length} bytes)');
      }
      return decodeU32LE(resp, 1);
    });
  }

  /// Sends an inquire frame and collects all responses until [timeout] fires.
  Future<List<int>> _inquireMulti(int cs, {required Duration timeout}) {
    return _lock.synchronized(() async {
      final results = <int>[];
      final done = Completer<void>();
      StreamSubscription<CanMessage>? sub;

      sub = _adapter.rxFrames.listen((msg) {
        if (msg.cobId == CobId.lss &&
            msg.data.isNotEmpty &&
            msg.data[0] == cs &&
            msg.data.length >= 5) {
          results.add(decodeU32LE(msg.data, 1));
        }
      });

      final timer = Timer(timeout, () {
        if (!done.isCompleted) done.complete();
      });

      await _adapter
          .send(CanMessage(cobId: CobId.lssMaster, data: _buildFrame(cs, [])));

      await done.future;
      timer.cancel();
      await sub.cancel();

      return results;
    });
  }

  // ── Frame builder ─────────────────────────────────────────────────────────

  /// Builds an 8-byte LSS frame with [cs] as byte[0] and [payload] in
  /// bytes[1..n]; remaining bytes are zero-padded.
  static Uint8List _buildFrame(int cs, List<int> payload) {
    final frame = Uint8List(8);
    frame[0] = cs;
    for (var i = 0; i < payload.length && i < 7; i++) {
      frame[1 + i] = payload[i];
    }
    return frame;
  }
}
