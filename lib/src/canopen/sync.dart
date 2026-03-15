/// SYNC manager — CiA 301 §7.3.5.
///
/// Produces SYNC messages (COB-ID 0x080) with optional counter (1–240),
/// and dispatches received SYNC frames to registered callbacks.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:canopen_client/src/canopen/message.dart';
import 'package:canopen_client/src/hardware/i_can_adapter.dart';

/// COB-ID for SYNC messages.
const int _syncCobId = 0x080;

/// Maximum SYNC counter value before wrapping back to 1.
const int _syncCounterMax = 240;

// ── SyncManager ───────────────────────────────────────────────────────────────

/// CANopen SYNC manager.
///
/// ## Usage
/// ```dart
/// final sync = SyncManager(adapter);
///
/// // Enable counter and send SYNC frames.
/// sync.setSyncCounterEnabled(true);
/// await sync.sendSync(); // sends [0x01]
/// await sync.sendSync(); // sends [0x02]
///
/// // React to incoming SYNC frames.
/// sync.registerSyncCallback((counter) => print('SYNC counter: $counter'));
///
/// sync.dispose();
/// ```
class SyncManager {
  /// Creates a [SyncManager] using [adapter] for CAN communication.
  SyncManager(this._adapter) {
    _rxSub = _adapter.rxFrames.listen(_onFrame);
  }

  final ICanAdapter _adapter;
  late StreamSubscription<CanMessage> _rxSub;

  bool _counterEnabled = false;
  int _counter = 0; // 0 = not yet sent; increments to 1 on first send
  final List<void Function(int?)> _callbacks = [];

  // ── Public API ────────────────────────────────────────────────────────────

  /// Transmits a SYNC message.
  ///
  /// - Counter disabled (default): sends a 0-byte frame on COB-ID `0x080`.
  /// - Counter enabled: increments the counter (wraps 1–240) and sends a
  ///   1-byte frame carrying the counter value.
  Future<void> sendSync() async {
    final Uint8List payload;
    if (_counterEnabled) {
      _counter = (_counter % _syncCounterMax) + 1;
      payload = Uint8List.fromList([_counter]);
    } else {
      payload = Uint8List(0);
    }
    await _adapter.send(CanMessage(cobId: _syncCobId, data: payload));
  }

  /// Enables or disables the SYNC counter.
  ///
  /// When enabled, each [sendSync] call increments the counter (1–240).
  /// When disabled, SYNC frames are sent without a counter byte.
  void setSyncCounterEnabled(bool enabled) {
    _counterEnabled = enabled;
  }

  /// Resets the counter to 0 so the next send starts from 1.
  void resetCounter() {
    _counter = 0;
  }

  /// Registers [callback] to be called whenever a SYNC frame is received.
  ///
  /// The argument is the counter byte value, or `null` if the frame carried
  /// no counter (i.e. data was empty).
  void registerSyncCallback(void Function(int? counter) callback) {
    _callbacks.add(callback);
  }

  /// Removes a previously registered [callback].
  ///
  /// Does nothing if [callback] is not registered.
  void unregisterSyncCallback(void Function(int? counter) callback) {
    _callbacks.remove(callback);
  }

  /// Cancels the RX subscription and clears all callbacks.
  void dispose() {
    _rxSub.cancel();
    _callbacks.clear();
  }

  // ── Private ───────────────────────────────────────────────────────────────

  void _onFrame(CanMessage msg) {
    if (msg.cobId != _syncCobId) return;
    final counter = msg.data.isNotEmpty ? msg.data[0] : null;
    for (final cb in List.of(_callbacks)) {
      cb(counter);
    }
  }
}
