/// PDO (Process Data Object) manager — CiA 301 §7.3.
///
/// Handles transmitting PDO frames and dispatching incoming PDO frames to
/// registered callbacks. Multiple callbacks per COB-ID are supported.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:canopen_client/src/canopen/message.dart';
import 'package:canopen_client/src/errors.dart';
import 'package:canopen_client/src/hardware/i_can_adapter.dart';

/// Maximum payload length for a PDO frame (CAN data field limit).
const int _maxPdoLength = 8;

// ── PdoManager ───────────────────────────────────────────────────────────────

/// CANopen PDO manager for transmitting and receiving Process Data Objects.
///
/// ## Usage
/// ```dart
/// final pdo = PdoManager(adapter);
///
/// // Receive: register a callback for a TPDO COB-ID.
/// pdo.registerPdoCallback(0x185, (data) {
///   print('TPDO from node 5: $data');
/// });
///
/// // Transmit: send an RPDO to a node.
/// await pdo.sendPdo(0x205, Uint8List.fromList([0x01, 0x00]));
///
/// pdo.dispose();
/// ```
class PdoManager {
  /// Creates a [PdoManager] using [adapter] for CAN communication.
  PdoManager(this._adapter) {
    _rxSub = _adapter.rxFrames.listen(_onFrame);
  }

  final ICanAdapter _adapter;
  final Map<int, List<void Function(Uint8List)>> _callbacks = {};
  late StreamSubscription<CanMessage> _rxSub;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Transmits a PDO frame with [cobId] and [data] payload.
  ///
  /// [data] must be 1–8 bytes; throws [CanOpenException] otherwise.
  Future<void> sendPdo(int cobId, Uint8List data) async {
    if (data.isEmpty || data.length > _maxPdoLength) {
      throw CanOpenException(
        'PDO data length ${data.length} is invalid; must be 1–$_maxPdoLength bytes.',
      );
    }
    await _adapter.send(CanMessage(cobId: cobId, data: data));
  }

  /// Registers [callback] to be called whenever a frame with [cobId] arrives.
  ///
  /// Multiple callbacks may be registered for the same [cobId]; all will fire.
  void registerPdoCallback(int cobId, void Function(Uint8List data) callback) {
    _callbacks.putIfAbsent(cobId, () => []).add(callback);
  }

  /// Removes all callbacks registered for [cobId].
  void unregisterAllCallbacks(int cobId) {
    _callbacks.remove(cobId);
  }

  /// Cancels the RX subscription and clears all registered callbacks.
  void dispose() {
    _rxSub.cancel();
    _callbacks.clear();
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _onFrame(CanMessage msg) {
    final cbs = _callbacks[msg.cobId];
    if (cbs == null) return;
    for (final cb in List.of(cbs)) {
      cb(msg.data);
    }
  }
}
