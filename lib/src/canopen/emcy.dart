/// EMCY (Emergency) manager — CiA 301 §7.2.7.
///
/// Receives Emergency frames (COB-IDs 0x081–0x0FF), parses them into
/// [EmcyMessage] objects, maintains a per-node history ring buffer, and
/// dispatches them to registered handlers.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:canopen_client/src/canopen/message.dart';
import 'package:canopen_client/src/hardware/i_can_adapter.dart';
import 'package:canopen_client/src/utils.dart';

/// First COB-ID of the EMCY range (node 1).
const int _emcyCobIdMin = 0x081;

/// Last COB-ID of the EMCY range (node 127).
const int _emcyCobIdMax = 0x0FF;

/// Maximum number of EMCY messages retained per node.
const int _maxHistory = 50;

// ── EmcyMessage ───────────────────────────────────────────────────────────────

/// A parsed CANopen Emergency message.
///
/// Layout of the 8-byte EMCY frame payload:
///
/// | Bytes | Field              |
/// |-------|--------------------|
/// | 0–1   | Error code (LE)    |
/// | 2     | Error register     |
/// | 3–7   | Manufacturer-specific data |
class EmcyMessage {
  /// Creates an [EmcyMessage].
  const EmcyMessage({
    required this.nodeId,
    required this.errorCode,
    required this.errorRegister,
    required this.mfrSpecificData,
    required this.timestamp,
  });

  /// Node ID of the device that sent this emergency (1–127).
  final int nodeId;

  /// CiA 301 emergency error code (2 bytes, little-endian).
  final int errorCode;

  /// CiA 301 error register (object 0x1001).
  final int errorRegister;

  /// Manufacturer-specific error bytes (5 bytes: payload[3..7]).
  final Uint8List mfrSpecificData;

  /// Local time when this message was received.
  final DateTime timestamp;

  /// Human-readable description of [errorCode] based on CiA 301 error groups.
  String get errorCodeDescription => _describeErrorCode(errorCode);

  @override
  String toString() =>
      'EmcyMessage(node=$nodeId, errorCode=0x${errorCode.toRadixString(16).toUpperCase().padLeft(4, '0')}, '
      'errorRegister=0x${errorRegister.toRadixString(16).toUpperCase().padLeft(2, '0')}, '
      '"$errorCodeDescription")';
}

String _describeErrorCode(int code) {
  if (code == 0x0000) return 'No error';
  final group = (code >> 12) & 0xF;
  switch (group) {
    case 0x1:
      return 'Generic error';
    case 0x2:
      return 'Current error';
    case 0x3:
      return 'Voltage error';
    case 0x4:
      return 'Temperature error';
    case 0x5:
      return 'Device hardware error';
    case 0x6:
      return 'Device software error';
    case 0x7:
      return 'Additional modules error';
    case 0x8:
      return 'Monitoring error';
    case 0x9:
      return 'External error';
    case 0xF:
      return 'Device specific error';
    default:
      return 'Unknown error (0x${code.toRadixString(16).toUpperCase().padLeft(4, '0')})';
  }
}

// ── EmcyManager ───────────────────────────────────────────────────────────────

/// CANopen EMCY manager.
///
/// ## Usage
/// ```dart
/// final emcy = EmcyManager(adapter);
///
/// emcy.registerEmcyHandler(5, (msg) {
///   print('EMCY from node 5: ${msg.errorCodeDescription}');
/// });
///
/// final recent = emcy.getRecentEmcy(5);
/// emcy.dispose();
/// ```
class EmcyManager {
  /// Creates an [EmcyManager] using [adapter] for CAN communication.
  EmcyManager(this._adapter) {
    _rxSub = _adapter.rxFrames.listen(_onFrame);
  }

  final ICanAdapter _adapter;
  late StreamSubscription<CanMessage> _rxSub;

  final Map<int, List<EmcyMessage>> _history = {};
  final Map<int, void Function(EmcyMessage)> _handlers = {};

  // ── Public API ────────────────────────────────────────────────────────────

  /// Registers [handler] to be called whenever an EMCY frame from [nodeId]
  /// is received.
  ///
  /// Only one handler per node is supported; a subsequent call for the same
  /// [nodeId] replaces the previous handler.
  void registerEmcyHandler(int nodeId, void Function(EmcyMessage) handler) {
    _handlers[nodeId] = handler;
  }

  /// Removes the handler registered for [nodeId], if any.
  void unregisterEmcyHandler(int nodeId) {
    _handlers.remove(nodeId);
  }

  /// Returns the most recent [count] EMCY messages received from [nodeId],
  /// newest last.
  ///
  /// Returns an empty list if no messages have been received from [nodeId].
  List<EmcyMessage> getRecentEmcy(int nodeId, {int count = 10}) {
    final history = _history[nodeId];
    if (history == null || history.isEmpty) return const [];
    final start = history.length > count ? history.length - count : 0;
    return history.sublist(start);
  }

  /// Clears the EMCY history for [nodeId].
  void clearHistory(int nodeId) {
    _history[nodeId]?.clear();
  }

  /// Cancels the RX subscription and clears all state.
  void dispose() {
    _rxSub.cancel();
    _history.clear();
    _handlers.clear();
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _onFrame(CanMessage msg) {
    if (msg.cobId < _emcyCobIdMin || msg.cobId > _emcyCobIdMax) return;
    if (msg.data.length < 8) return;

    final nodeId = msg.cobId - 0x080;
    final errorCode = decodeU16LE(msg.data);
    final errorRegister = msg.data[2];
    final mfrData = Uint8List.fromList(msg.data.sublist(3, 8));

    final emcy = EmcyMessage(
      nodeId: nodeId,
      errorCode: errorCode,
      errorRegister: errorRegister,
      mfrSpecificData: mfrData,
      timestamp: DateTime.now(),
    );

    final list = _history.putIfAbsent(nodeId, () => []);
    list.add(emcy);
    if (list.length > _maxHistory) {
      list.removeAt(0);
    }

    _handlers[nodeId]?.call(emcy);
  }
}
