/// LSS (Layer Setting Services) client — CiA 305.
///
/// Supports switch-state, inquire, configure node-ID / bit-timing,
/// store configuration, and Fastscan discovery.
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

/// Configure Node-ID command specifier (request & response share cs byte).
const int lssCsConfigureNodeId = 0x11;

/// Configure Bit-Timing command specifier (request & response share cs byte).
const int lssCsConfigureBitTiming = 0x13;

/// Activate Bit-Timing command specifier (fire-and-forget).
const int lssCsActivateBitTiming = 0x15;

/// Store Configuration command specifier (request & response share cs byte).
const int lssCsStoreConfiguration = 0x17;

/// Fastscan command specifier (master → slaves).
const int lssCsFastscan = 0x51;

/// Fastscan response cs byte (same as Identify Slave).
const int lssCsFastscanResponse = 0x4F;

// ── LssError ─────────────────────────────────────────────────────────────────

/// Error codes returned in LSS configure and store responses.
enum LssError {
  /// Operation succeeded.
  success(0),

  /// Node-ID out of range (not 1–127).
  nodeIdOutOfRange(1),

  /// Manufacturer-specific error.
  specificError(0xFF);

  /// Creates an [LssError] with numeric [code].
  const LssError(this.code);

  /// The numeric error code from the LSS response byte.
  final int code;

  /// Returns a human-readable description of the error.
  String get description => switch (this) {
        LssError.success => 'Success',
        LssError.nodeIdOutOfRange => 'Node-ID out of range',
        LssError.specificError => 'Manufacturer-specific error',
      };

  /// Parses a raw LSS error byte into an [LssError].
  static LssError fromByte(int byte) => switch (byte) {
        0 => LssError.success,
        1 => LssError.nodeIdOutOfRange,
        _ => LssError.specificError,
      };
}

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

  // ── Configure / Store ─────────────────────────────────────────────────────

  /// Configures the node-ID of the selected LSS slave.
  ///
  /// [nodeId] must be in the range 1–127; some implementations also allow 255
  /// (unconfigured). The slave must be in configuration mode.
  ///
  /// Returns [LssError.success] on acknowledgement, or an appropriate error
  /// code if the slave rejects the value.
  ///
  /// Throws [CanOpenTimeoutException] if no response arrives within [timeout].
  Future<LssError> lssConfigureNodeId(
    int nodeId, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    return _lock.synchronized(() async {
      final req = _buildFrame(lssCsConfigureNodeId, [nodeId & 0xFF]);
      final resp = await _transact(
        req,
        lssCsConfigureNodeId,
        timeout: timeout,
        context: 'LSS configure node-ID',
      );
      // byte[1] = error code, byte[2] = spec error (used when code = 0xFF).
      return LssError.fromByte(resp.length > 1 ? resp[1] : 0);
    });
  }

  /// Configures the bit-timing parameters of the selected LSS slave.
  ///
  /// [tableSelector] selects the bit-timing table (0 = CiA standard table).
  /// [tableIndex] selects the entry within the table (0–9 for standard table).
  ///
  /// Returns [LssError.success] on acknowledgement.
  ///
  /// Throws [CanOpenTimeoutException] if no response arrives within [timeout].
  Future<LssError> lssConfigureBitTiming(
    int tableSelector,
    int tableIndex, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    return _lock.synchronized(() async {
      final req = _buildFrame(
          lssCsConfigureBitTiming, [tableSelector & 0xFF, tableIndex & 0xFF]);
      final resp = await _transact(
        req,
        lssCsConfigureBitTiming,
        timeout: timeout,
        context: 'LSS configure bit timing',
      );
      return LssError.fromByte(resp.length > 1 ? resp[1] : 0);
    });
  }

  /// Activates the new bit-timing parameters on the selected LSS slave.
  ///
  /// [switchDelayMs] is the delay in milliseconds the slave waits before and
  /// after switching (CiA 305 §6.4.4).  This is fire-and-forget — no response
  /// is expected.
  Future<void> lssActivateBitTiming(int switchDelayMs) {
    return _lock.synchronized(() async {
      final delayLow = switchDelayMs & 0xFF;
      final delayHigh = (switchDelayMs >> 8) & 0xFF;
      final req = _buildFrame(lssCsActivateBitTiming, [delayLow, delayHigh]);
      await _adapter.send(CanMessage(cobId: CobId.lssMaster, data: req));
    });
  }

  /// Stores the current node-ID and bit-timing configuration to NVM on the
  /// selected LSS slave.
  ///
  /// Returns [LssError.success] on acknowledgement.
  ///
  /// Throws [CanOpenTimeoutException] if no response arrives within [timeout].
  Future<LssError> lssStoreConfiguration({
    Duration timeout = const Duration(seconds: 1),
  }) {
    return _lock.synchronized(() async {
      final req = _buildFrame(lssCsStoreConfiguration, []);
      final resp = await _transact(
        req,
        lssCsStoreConfiguration,
        timeout: timeout,
        context: 'LSS store configuration',
      );
      return LssError.fromByte(resp.length > 1 ? resp[1] : 0);
    });
  }

  // ── Fastscan ──────────────────────────────────────────────────────────────

  /// Discovers all unconfigured LSS slaves on the network using a simplified
  /// Fastscan broadcast.
  ///
  /// For each responding device:
  /// 1. Reads the four identity fields via inquire.
  /// 2. Assigns a node-ID starting from [startNodeId] (incrementing).
  /// 3. Adds the [LssAddress] to the result list.
  ///
  /// The probe is repeated until no device responds within [probeTimeout].
  ///
  /// [timeout]      — Total maximum time for the entire scan.
  /// [probeTimeout] — Timeout for each individual probe and inquire.
  /// [startNodeId]  — Node-ID assigned to the first discovered device.
  Future<List<LssAddress>> lssFastscan({
    Duration timeout = const Duration(seconds: 5),
    Duration probeTimeout = const Duration(milliseconds: 200),
    int startNodeId = 1,
  }) async {
    final results = <LssAddress>[];
    var nextNodeId = startNodeId;
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline) && nextNodeId <= 127) {
      // Probe: Fastscan broadcast with BitChecked=0x80 (match-all sweep).
      final probeReq = _buildFastscanFrame(
        idNumber: 0,
        bitChecked: 0x80,
        lssSub: 0,
        lssNext: 0,
      );

      try {
        await _transact(
          probeReq,
          lssCsFastscanResponse,
          timeout: probeTimeout,
          context: 'LSS fastscan probe',
        );
      } on CanOpenTimeoutException {
        break; // No more devices.
      }

      // Read all four identity fields.
      int vendorId, productCode, revisionNumber, serialNumber;
      try {
        vendorId =
            await _inquireUnlocked(lssCsInquireVendorId, timeout: probeTimeout);
        productCode = await _inquireUnlocked(lssCsInquireProductCode,
            timeout: probeTimeout);
        revisionNumber = await _inquireUnlocked(lssCsInquireRevisionNumber,
            timeout: probeTimeout);
        serialNumber = await _inquireUnlocked(lssCsInquireSerialNumber,
            timeout: probeTimeout);
      } on CanOpenTimeoutException {
        break; // Lost the device mid-scan.
      }

      results.add(LssAddress(
        vendorId: vendorId,
        productCode: productCode,
        revisionNumber: revisionNumber,
        serialNumber: serialNumber,
      ));

      // Assign a node-ID and store it.
      try {
        await _configureNodeIdUnlocked(nextNodeId, timeout: probeTimeout);
        await _storeConfigurationUnlocked(timeout: probeTimeout);
      } on CanOpenTimeoutException {
        // Continue — the address was already recorded.
      }

      nextNodeId++;
    }

    return results;
  }

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

  // ── Frame builders ────────────────────────────────────────────────────────

  /// Builds an 8-byte LSS Fastscan frame.
  static Uint8List _buildFastscanFrame({
    required int idNumber,
    required int bitChecked,
    required int lssSub,
    required int lssNext,
  }) {
    final frame = Uint8List(8);
    frame[0] = lssCsFastscan;
    frame[1] = idNumber & 0xFF;
    frame[2] = (idNumber >> 8) & 0xFF;
    frame[3] = (idNumber >> 16) & 0xFF;
    frame[4] = (idNumber >> 24) & 0xFF;
    frame[5] = bitChecked & 0xFF;
    frame[6] = lssSub & 0xFF;
    frame[7] = lssNext & 0xFF;
    return frame;
  }

  /// Inquire helper that does NOT acquire [_lock] — for use inside Fastscan
  /// which already holds the lock via its outer context.
  Future<int> _inquireUnlocked(int cs, {required Duration timeout}) async {
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
  }

  /// Configure node-ID without acquiring [_lock].
  Future<LssError> _configureNodeIdUnlocked(
    int nodeId, {
    required Duration timeout,
  }) async {
    final req = _buildFrame(lssCsConfigureNodeId, [nodeId & 0xFF]);
    final resp = await _transact(
      req,
      lssCsConfigureNodeId,
      timeout: timeout,
      context: 'LSS configure node-ID',
    );
    return LssError.fromByte(resp.length > 1 ? resp[1] : 0);
  }

  /// Store configuration without acquiring [_lock].
  Future<LssError> _storeConfigurationUnlocked(
      {required Duration timeout}) async {
    final req = _buildFrame(lssCsStoreConfiguration, []);
    final resp = await _transact(
      req,
      lssCsStoreConfiguration,
      timeout: timeout,
      context: 'LSS store configuration',
    );
    return LssError.fromByte(resp.length > 1 ? resp[1] : 0);
  }

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
