/// SDO (Service Data Object) client — CiA 301 §7.2.
///
/// Supports expedited transfers (≤ 4 bytes) and segmented transfers (> 4 bytes).
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

// Segmented upload segment request (client → server): cs = 011.
const int _csUploadSegReq = 0x60;

// Segmented upload segment response (server → client): cs = 000.
const int _csUploadSegRsp = 0x00;

// Segmented download segment ACK (server → client): cs = 001.
const int _csDownloadSegAck = 0x20;

// ── SdoClient ────────────────────────────────────────────────────────────────

/// CANopen SDO client providing read/write access to remote node object
/// dictionaries.
///
/// Supports:
/// - **Expedited** transfers (≤ 4 bytes).
/// - **Segmented** transfers (> 4 bytes) — automatically selected when needed.
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
  /// Handles both expedited (≤ 4 bytes) and segmented (> 4 bytes) transfers
  /// transparently — the transfer type is determined by the node's response.
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
    final ctx = 'SDO read 0x${index.toRadixString(16)}/$subIndex';
    return _lockFor(nodeId).synchronized(() async {
      final req = _buildUploadRequest(index, subIndex);
      final initResp =
          await _transact(nodeId, req, timeout: timeout, context: ctx);

      if (initResp.isEmpty) {
        throw const CanOpenException('SDO response is empty');
      }
      if (initResp[0] == _csAbort) {
        final abortCode = initResp.length >= 8 ? decodeU32LE(initResp, 4) : 0;
        throw SdoAbortException(abortCode);
      }
      if ((initResp[0] & _csMask) != _csUploadReq) {
        throw CanOpenException(
          'Unexpected SDO upload initiate response: '
          '0x${initResp[0].toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }

      final eFlag = (initResp[0] & 0x02) != 0; // expedited
      if (eFlag) {
        // Expedited: data in bytes [4 .. 4+dataLen).
        final sFlag = (initResp[0] & 0x01) != 0;
        final n = sFlag ? (initResp[0] >> 2) & 0x03 : 0;
        final dataLen = 4 - n;
        return Uint8List.fromList(initResp.sublist(4, 4 + dataLen));
      } else {
        // Segmented upload.
        return _segmentedUpload(
          nodeId,
          timeout: timeout,
          context: ctx,
        );
      }
    });
  }

  /// Writes a value to a remote object dictionary entry via SDO download.
  ///
  /// Data ≤ 4 bytes uses an expedited transfer; larger data is sent using
  /// a segmented transfer automatically.
  ///
  /// [nodeId]   — Target node (1–127).
  /// [index]    — Object dictionary index.
  /// [subIndex] — Sub-index.
  /// [data]     — Raw bytes to write.
  /// [timeout]  — Maximum time to wait for a response.
  ///
  /// Throws [SdoAbortException] if the remote node aborts the transfer.
  /// Throws [CanOpenTimeoutException] if no response arrives within [timeout].
  /// Throws [CanOpenException] if [data] is empty or an unexpected response
  /// is received.
  Future<void> sdoWrite(
    int nodeId,
    int index,
    int subIndex,
    Uint8List data, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    if (data.isEmpty) {
      throw const CanOpenException('SDO write data must not be empty');
    }
    return _lockFor(nodeId).synchronized(() async {
      if (data.length <= 4) {
        // Expedited download.
        final req = _buildDownloadRequest(index, subIndex, data);
        final response = await _transact(
          nodeId,
          req,
          timeout: timeout,
          context: 'SDO write 0x${index.toRadixString(16)}/$subIndex',
        );
        _parseDownloadResponse(response, index, subIndex);
      } else {
        // Segmented download.
        await _segmentedDownload(
          nodeId,
          index,
          subIndex,
          data,
          timeout: timeout,
        );
      }
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
  /// segmented initiation.
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

  /// Reads a 64-bit IEEE 754 double from the remote object dictionary.
  ///
  /// Typically uses a segmented transfer (8 bytes > 4-byte expedited limit).
  Future<double> sdoReadF64(
    int nodeId,
    int index,
    int subIndex, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final data = await sdoRead(nodeId, index, subIndex, timeout: timeout);
    if (data.length < 8) {
      throw CanOpenException(
          'SDO read returned ${data.length} byte(s), expected ≥ 8');
    }
    return decodeF64LE(data);
  }

  /// Writes a 64-bit IEEE 754 double to the remote object dictionary.
  ///
  /// Automatically uses segmented transfer (8 bytes).
  Future<void> sdoWriteF64(
    int nodeId,
    int index,
    int subIndex,
    double value, {
    Duration timeout = const Duration(seconds: 1),
  }) =>
      sdoWrite(nodeId, index, subIndex, encodeF64LE(value), timeout: timeout);

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

  /// Builds an 8-byte SDO segmented download initiate request.
  ///
  /// Sets e=0 (segmented), s=1 (size indicated), with [dataLength] in
  /// bytes [4..7] LE.
  static Uint8List _buildSegmentedDownloadInitiate(
      int index, int subIndex, int dataLength) {
    final frame = Uint8List(8);
    // cs=001 (download initiate), e=0, s=1 → 0x20 | 0x01 = 0x21
    frame[0] = 0x21;
    frame[1] = index & 0xFF;
    frame[2] = (index >> 8) & 0xFF;
    frame[3] = subIndex & 0xFF;
    frame[4] = dataLength & 0xFF;
    frame[5] = (dataLength >> 8) & 0xFF;
    frame[6] = (dataLength >> 16) & 0xFF;
    frame[7] = (dataLength >> 24) & 0xFF;
    return frame;
  }

  // ── Response parsers ──────────────────────────────────────────────────────

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

  // ── Segmented transfers ───────────────────────────────────────────────────

  /// Performs a segmented SDO upload (read > 4 bytes).
  ///
  /// Called after the initiate response confirms a segmented transfer.
  /// Loops sending upload-segment requests until the node sets the
  /// "last segment" (c) bit.
  ///
  /// [indicatedSize] — Total byte count from the initiate response (0 if
  ///   the node did not set the s-bit, i.e. size is unknown in advance).
  Future<Uint8List> _segmentedUpload(
    int nodeId, {
    required Duration timeout,
    required String context,
  }) async {
    final accumulator = <int>[];
    var toggle = 0;

    while (true) {
      // Upload segment request: cs=011, toggle in bit 4.
      final segReq = Uint8List(8);
      segReq[0] = _csUploadSegReq | (toggle << 4);

      final segResp =
          await _transact(nodeId, segReq, timeout: timeout, context: context);

      if (segResp.isEmpty) {
        throw const CanOpenException('SDO upload segment response is empty');
      }
      if (segResp[0] == _csAbort) {
        final abortCode = segResp.length >= 8 ? decodeU32LE(segResp, 4) : 0;
        throw SdoAbortException(abortCode);
      }
      // Upload segment response: cs = 000 (bits 7:5).
      if ((segResp[0] & _csMask) != _csUploadSegRsp) {
        throw CanOpenException(
          'Unexpected SDO upload segment response: '
          '0x${segResp[0].toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }

      final respToggle = (segResp[0] >> 4) & 0x01;
      if (respToggle != toggle) {
        throw CanOpenException(
          'SDO upload segment toggle mismatch: '
          'expected $toggle, got $respToggle',
        );
      }

      final n = (segResp[0] >> 1) & 0x07; // unused bytes at end of segment
      final c = segResp[0] & 0x01; // 1 = last segment
      final segDataLen = 7 - n;

      if (segDataLen > 0) {
        accumulator.addAll(segResp.sublist(1, 1 + segDataLen));
      }

      toggle = 1 - toggle;

      if (c == 1) {
        break;
      }
    }

    return Uint8List.fromList(accumulator);
  }

  /// Performs a segmented SDO download (write > 4 bytes).
  ///
  /// Sends a segmented download initiate request, awaits the node's ACK,
  /// then sends data in 7-byte chunks until all [data] is transferred.
  Future<void> _segmentedDownload(
    int nodeId,
    int index,
    int subIndex,
    Uint8List data, {
    required Duration timeout,
  }) async {
    final context = 'SDO write 0x${index.toRadixString(16)}/$subIndex';

    // ── Initiation ──────────────────────────────────────────────────────────
    final initReq =
        _buildSegmentedDownloadInitiate(index, subIndex, data.length);
    final initResp =
        await _transact(nodeId, initReq, timeout: timeout, context: context);

    if (initResp.isEmpty) {
      throw const CanOpenException('SDO response is empty');
    }
    if (initResp[0] == _csAbort) {
      final abortCode = initResp.length >= 8 ? decodeU32LE(initResp, 4) : 0;
      throw SdoAbortException(abortCode);
    }
    // Initiate download response: cs = 011 = 0x60.
    if ((initResp[0] & _csMask) != _csDownloadRsp) {
      throw CanOpenException(
        'Unexpected SDO download initiate response: '
        '0x${initResp[0].toRadixString(16).toUpperCase().padLeft(2, '0')}',
      );
    }

    // ── Segment loop ────────────────────────────────────────────────────────
    var toggle = 0;
    var offset = 0;

    while (offset < data.length) {
      final remaining = data.length - offset;
      final segLen = remaining < 7 ? remaining : 7;
      final isLast = (offset + segLen) >= data.length;
      final n = 7 - segLen; // unused bytes in this segment frame
      final c = isLast ? 1 : 0; // last-segment flag

      // Download segment request: cs=000, toggle in bit4, n in bits[3:1], c in bit0.
      final segReq = Uint8List(8);
      segReq[0] = (toggle << 4) | (n << 1) | c;
      segReq.setRange(1, 1 + segLen, data, offset);

      final segResp =
          await _transact(nodeId, segReq, timeout: timeout, context: context);

      if (segResp.isEmpty) {
        throw const CanOpenException('SDO download segment ACK is empty');
      }
      if (segResp[0] == _csAbort) {
        final abortCode = segResp.length >= 8 ? decodeU32LE(segResp, 4) : 0;
        throw SdoAbortException(abortCode);
      }
      // Download segment ACK: cs = 001 = 0x20.
      if ((segResp[0] & _csMask) != _csDownloadSegAck) {
        throw CanOpenException(
          'Unexpected SDO download segment ACK: '
          '0x${segResp[0].toRadixString(16).toUpperCase().padLeft(2, '0')}',
        );
      }

      final respToggle = (segResp[0] >> 4) & 0x01;
      if (respToggle != toggle) {
        throw CanOpenException(
          'SDO download segment toggle mismatch: '
          'expected $toggle, got $respToggle',
        );
      }

      toggle = 1 - toggle;
      offset += segLen;
    }
  }
}
