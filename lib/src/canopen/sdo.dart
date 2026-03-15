/// SDO (Service Data Object) client — CiA 301 §7.2.
///
/// Phase 3 implements expedited transfers (≤ 4 bytes).
/// Phase 4 will extend this with segmented transfers (> 4 bytes).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:synchronized/synchronized.dart';

import 'package:canopen_client/src/canopen/message.dart';
import 'package:canopen_client/src/errors.dart';
import 'package:canopen_client/src/hardware/i_can_adapter.dart';
import 'package:canopen_client/src/utils.dart';

// ── SDO command specifier byte constants ─────────────────────────────────────

/// Expedited/segmented upload (read) request byte: cs=2.
const int _csUploadReq = 0x40;

/// Expedited download (write) initiate response byte: cs=3.
const int _csDownloadRsp = 0x60;

/// Abort transfer byte: cs=4.
const int _csAbort = 0x80;

/// Upper 3 bits mask for separating the command specifier.
const int _csMask = 0xE0;

// ── SdoClient ────────────────────────────────────────────────────────────────

/// CANopen SDO client providing read/write access to remote node object
/// dictionaries.
///
/// Supports:
/// - **Expedited** transfers (≤ 4 bytes) — Phase 3.
/// - **Segmented** transfers (> 4 bytes) — Phase 4 extension.
///
/// All operations are serialised per node using a [Lock] to prevent overlapping
/// transactions on the same SDO channel.
///
/// ## Usage
/// ```dart
/// final sdo = SdoClient(adapter);
///
/// final deviceType = await sdo.sdoReadU32(5, 0x1000, 0);
/// await sdo.sdoWriteU16(5, 0x1017, 0, 1000);
///
/// sdo.dispose();
/// ```
class SdoClient {
  /// Creates an [SdoClient] using [adapter] for CAN communication.
  SdoClient(this._adapter);

  final ICanAdapter _adapter;

  /// Per-node mutex — one [Lock] per node ID.
  final Map<int, Lock> _locks = {};

  Lock _lockFor(int nodeId) => _locks.putIfAbsent(nodeId, Lock.new);

  // ── Raw read / write ──────────────────────────────────────────────────────

  /// Reads a remote object dictionary entry via SDO upload.
  ///
  /// Handles expedited (≤ 4 bytes) transfers transparently.
  /// Segmented transfers (> 4 bytes) require Phase 4 — a
  /// [CanOpenException] is thrown if the node responds with a
  /// segmented initiation.
  ///
  /// [nodeId]   — Target node (1–127).
  /// [index]    — Object dictionary index (e.g. `0x1000`).
  /// [subIndex] — Sub-index (e.g. `0x00`).
  /// [timeout]  — Maximum time to wait for a response.
  ///
  /// Throws [SdoAbortException] if the remote node aborts the transfer.
  /// Throws [CanOpenTimeoutException] if no response arrives within [timeout].
  /// Throws [CanOpenException] for unexpected response formats.
  Future<Uint8List> sdoRead(
    int nodeId,
    int index,
    int subIndex, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    return _lockFor(nodeId).synchronized(() async {
      // Build 8-byte upload request.
      final req = _buildUploadRequest(index, subIndex);
      final response = await _transact(nodeId, req,
          timeout: timeout,
          context: 'SDO read 0x${index.toRadixString(16)}/$subIndex');

      return _parseUploadResponse(response, index, subIndex);
    });
  }

  /// Writes a value to a remote object dictionary entry via SDO download.
  ///
  /// Data ≤ 4 bytes uses an expedited transfer.
  /// Data > 4 bytes requires Phase 4 (segmented) — a [CanOpenException]
  /// is thrown until then.
  ///
  /// [nodeId]   — Target node (1–127).
  /// [index]    — Object dictionary index.
  /// [subIndex] — Sub-index.
  /// [data]     — Raw bytes to write (≤ 4 bytes for expedited).
  /// [timeout]  — Maximum time to wait for a response.
  ///
  /// Throws [SdoAbortException] if the remote node aborts the transfer.
  /// Throws [CanOpenTimeoutException] if no response arrives within [timeout].
  /// Throws [CanOpenException] if [data] is > 4 bytes (segmented not yet
  /// implemented).
  Future<void> sdoWrite(
    int nodeId,
    int index,
    int subIndex,
    Uint8List data, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    if (data.length > 4) {
      throw CanOpenException(
        'SDO segmented download not yet supported (Phase 4). '
        'Data length ${data.length} > 4 bytes.',
      );
    }
    return _lockFor(nodeId).synchronized(() async {
      final req = _buildDownloadRequest(index, subIndex, data);
      final response = await _transact(nodeId, req,
          timeout: timeout,
          context: 'SDO write 0x${index.toRadixString(16)}/$subIndex');

      _parseDownloadResponse(response, index, subIndex);
    });
  }

  // ── Typed read helpers ────────────────────────────────────────────────────

  /// Reads an 8-bit unsigned integer from the remote object dictionary.
  Future<int> sdoReadU8(
    int nodeId,
    int index,
    int subIndex, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final data = await sdoRead(nodeId, index, subIndex, timeout: timeout);
    if (data.isEmpty) {
      throw const CanOpenException('SDO read returned empty data');
    }
    return decodeU8(data);
  }

  /// Reads a 16-bit unsigned integer from the remote object dictionary.
  Future<int> sdoReadU16(
    int nodeId,
    int index,
    int subIndex, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final data = await sdoRead(nodeId, index, subIndex, timeout: timeout);
    if (data.length < 2) {
      throw CanOpenException(
          'SDO read returned ${data.length} byte(s), expected ≥ 2');
    }
    return decodeU16LE(data);
  }

  /// Reads a 32-bit unsigned integer from the remote object dictionary.
  Future<int> sdoReadU32(
    int nodeId,
    int index,
    int subIndex, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final data = await sdoRead(nodeId, index, subIndex, timeout: timeout);
    if (data.length < 4) {
      throw CanOpenException(
          'SDO read returned ${data.length} byte(s), expected ≥ 4');
    }
    return decodeU32LE(data);
  }

  /// Reads a 32-bit IEEE 754 float from the remote object dictionary.
  Future<double> sdoReadF32(
    int nodeId,
    int index,
    int subIndex, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final data = await sdoRead(nodeId, index, subIndex, timeout: timeout);
    if (data.length < 4) {
      throw CanOpenException(
          'SDO read returned ${data.length} byte(s), expected ≥ 4');
    }
    return decodeF32LE(data);
  }

  /// Reads a UTF-8 string from the remote object dictionary.
  ///
  /// Uses segmented transfer automatically when the node responds with a
  /// segmented initiation (requires Phase 4).
  Future<String> sdoReadString(
    int nodeId,
    int index,
    int subIndex, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final data = await sdoRead(nodeId, index, subIndex, timeout: timeout);
    return decodeString(data);
  }

  // ── Typed write helpers ───────────────────────────────────────────────────

  /// Writes an 8-bit unsigned integer to the remote object dictionary.
  Future<void> sdoWriteU8(
    int nodeId,
    int index,
    int subIndex,
    int value, {
    Duration timeout = const Duration(seconds: 1),
  }) =>
      sdoWrite(
        nodeId,
        index,
        subIndex,
        Uint8List.fromList([value & 0xFF]),
        timeout: timeout,
      );

  /// Writes a 16-bit unsigned integer to the remote object dictionary.
  Future<void> sdoWriteU16(
    int nodeId,
    int index,
    int subIndex,
    int value, {
    Duration timeout = const Duration(seconds: 1),
  }) =>
      sdoWrite(nodeId, index, subIndex, encodeU16LE(value), timeout: timeout);

  /// Writes a 32-bit unsigned integer to the remote object dictionary.
  Future<void> sdoWriteU32(
    int nodeId,
    int index,
    int subIndex,
    int value, {
    Duration timeout = const Duration(seconds: 1),
  }) =>
      sdoWrite(nodeId, index, subIndex, encodeU32LE(value), timeout: timeout);

  /// Writes a 32-bit IEEE 754 float to the remote object dictionary.
  Future<void> sdoWriteF32(
    int nodeId,
    int index,
    int subIndex,
    double value, {
    Duration timeout = const Duration(seconds: 1),
  }) =>
      sdoWrite(nodeId, index, subIndex, encodeF32LE(value), timeout: timeout);

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Releases resources (currently a no-op; reserved for future use).
  void dispose() {
    _locks.clear();
  }

  // ── Private core ──────────────────────────────────────────────────────────

  /// Sends [request] on the SDO receive channel for [nodeId] and awaits
  /// one response frame on the SDO transmit channel.
  ///
  /// Returns the raw 8-byte response payload.
  Future<Uint8List> _transact(
    int nodeId,
    Uint8List request, {
    required Duration timeout,
    required String context,
  }) async {
    final completer = Completer<Uint8List>();
    final rxCobId = CobId.sdoTx(nodeId);

    StreamSubscription<CanMessage>? sub;
    sub = _adapter.rxFrames.listen((msg) {
      if (msg.cobId == rxCobId && !completer.isCompleted) {
        completer.complete(msg.data);
        sub?.cancel();
      }
    });

    await _adapter.send(
      CanMessage(cobId: CobId.sdoRx(nodeId), data: request),
    );

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      await sub.cancel();
      throw CanOpenTimeoutException(context);
    }
  }

  // ── Frame builders ────────────────────────────────────────────────────────

  /// Builds an 8-byte SDO expedited upload initiate request.
  static Uint8List _buildUploadRequest(int index, int subIndex) {
    final frame = Uint8List(8);
    frame[0] = _csUploadReq;
    frame[1] = index & 0xFF;
    frame[2] = (index >> 8) & 0xFF;
    frame[3] = subIndex & 0xFF;
    return frame;
  }

  /// Builds an 8-byte SDO expedited (≤ 4 bytes) download initiate request.
  static Uint8List _buildDownloadRequest(
      int index, int subIndex, Uint8List data) {
    assert(data.isNotEmpty && data.length <= 4);
    final unusedBytes = 4 - data.length;
    // cs=1 (download), e=1 (expedited), s=1 (size indicated)
    final cmdByte = 0x20 | (unusedBytes << 2) | 0x02 | 0x01;
    final frame = Uint8List(8);
    frame[0] = cmdByte;
    frame[1] = index & 0xFF;
    frame[2] = (index >> 8) & 0xFF;
    frame[3] = subIndex & 0xFF;
    frame.setRange(4, 4 + data.length, data);
    return frame;
  }

  // ── Response parsers ──────────────────────────────────────────────────────

  /// Parses an SDO upload response and returns the data bytes.
  static Uint8List _parseUploadResponse(
      Uint8List resp, int index, int subIndex) {
    if (resp.isEmpty) {
      throw const CanOpenException('SDO response is empty');
    }

    final cs = resp[0] & _csMask;

    // Abort (cs = 4 → 0x80)
    if (resp[0] == _csAbort) {
      if (resp.length >= 8) {
        final abortCode = decodeU32LE(resp, 4);
        throw SdoAbortException(abortCode);
      }
      throw SdoAbortException(0);
    }

    // Upload response: cs = 2 → 0x40
    if (cs == _csUploadReq) {
      final eFlag = (resp[0] & 0x02) != 0; // expedited
      final sFlag = (resp[0] & 0x01) != 0; // size indicated

      if (!eFlag) {
        // Segmented initiation — not yet supported (Phase 4).
        throw CanOpenException(
          'SDO segmented upload not yet supported (Phase 4). '
          'Response from node for 0x${index.toRadixString(16)}/$subIndex '
          'indicates data > 4 bytes.',
        );
      }

      // Expedited: extract n (number of unused bytes in [4..7]).
      final n = sFlag ? (resp[0] >> 2) & 0x03 : 0;
      final dataLen = 4 - n;
      return Uint8List.fromList(resp.sublist(4, 4 + dataLen));
    }

    throw CanOpenException(
      'Unexpected SDO response byte: '
      '0x${resp[0].toRadixString(16).toUpperCase().padLeft(2, '0')}',
    );
  }

  /// Validates an SDO download (write) response.
  static void _parseDownloadResponse(Uint8List resp, int index, int subIndex) {
    if (resp.isEmpty) {
      throw const CanOpenException('SDO response is empty');
    }

    if (resp[0] == _csAbort) {
      if (resp.length >= 8) {
        final abortCode = decodeU32LE(resp, 4);
        throw SdoAbortException(abortCode);
      }
      throw SdoAbortException(0);
    }

    if ((resp[0] & _csMask) == _csDownloadRsp) {
      return; // success
    }

    throw CanOpenException(
      'Unexpected SDO download response byte: '
      '0x${resp[0].toRadixString(16).toUpperCase().padLeft(2, '0')}',
    );
  }
}
