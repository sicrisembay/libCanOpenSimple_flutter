/// NMT (Network Management) manager — CiA 301 §7.3.
///
/// Provides:
/// - Sending NMT commands (start, stop, pre-operational, reset) to any node.
/// - Consuming NMT heartbeat / boot-up messages and tracking per-node states.
/// - Registering callbacks that fire whenever a node's state changes.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:canopen_client/src/canopen/message.dart';
import 'package:canopen_client/src/canopen/types.dart';
import 'package:canopen_client/src/hardware/i_can_adapter.dart';

/// Manages NMT protocol operations for a CANopen master.
///
/// ## Usage
/// ```dart
/// final nmt = NmtManager(adapter);
///
/// // Send NMT command
/// await nmt.nmtStart(5);
///
/// // Monitor heartbeats
/// nmt.registerHeartbeatCallback(5, (nodeId, state) {
///   print('Node $nodeId → $state');
/// });
///
/// // Cleanup
/// nmt.dispose();
/// ```
class NmtManager {
  /// Creates an [NmtManager] that uses [adapter] for CAN communication.
  NmtManager(ICanAdapter adapter) : _adapter = adapter {
    _rxSub = adapter.rxFrames.listen(_onFrame);
  }

  final ICanAdapter _adapter;
  late final StreamSubscription<CanMessage> _rxSub;

  /// Last known state for each node, keyed by node ID (1–127).
  final Map<int, NmtState> _nodeStates = {};

  /// Single registered heartbeat callback per node ID.
  final Map<int, void Function(int nodeId, NmtState state)>
      _heartbeatCallbacks = {};

  // ── Public command API ───────────────────────────────────────────────────

  /// Transitions [nodeId] (or all nodes when [nodeId] is 0) to Operational.
  Future<void> nmtStart(int nodeId) => _sendCommand(NmtCommand.start, nodeId);

  /// Transitions [nodeId] (or all nodes when [nodeId] is 0) to Stopped.
  Future<void> nmtStop(int nodeId) => _sendCommand(NmtCommand.stop, nodeId);

  /// Transitions [nodeId] (or all nodes when [nodeId] is 0) to
  /// Pre-Operational.
  Future<void> nmtEnterPreOperational(int nodeId) =>
      _sendCommand(NmtCommand.enterPreOperational, nodeId);

  /// Resets the application of [nodeId] (or all nodes when [nodeId] is 0).
  Future<void> nmtResetNode(int nodeId) =>
      _sendCommand(NmtCommand.resetNode, nodeId);

  /// Resets only the communication layer of [nodeId] (or all nodes when
  /// [nodeId] is 0).
  Future<void> nmtResetCommunication(int nodeId) =>
      _sendCommand(NmtCommand.resetCommunication, nodeId);

  // ── State query ──────────────────────────────────────────────────────────

  /// Returns the last known [NmtState] for [nodeId].
  ///
  /// Returns [NmtState.unknown] if no heartbeat has been received yet.
  NmtState getNodeState(int nodeId) => _nodeStates[nodeId] ?? NmtState.unknown;

  // ── Callback registration ────────────────────────────────────────────────

  /// Registers [callback] to be called whenever [nodeId]'s state changes.
  ///
  /// Only one callback per node is supported. Registering again for the same
  /// [nodeId] replaces the previous callback.
  ///
  /// The callback receives the node ID and the new [NmtState].
  void registerHeartbeatCallback(
    int nodeId,
    void Function(int nodeId, NmtState state) callback,
  ) {
    _heartbeatCallbacks[nodeId] = callback;
  }

  /// Removes any registered heartbeat callback for [nodeId].
  void unregisterHeartbeatCallback(int nodeId) {
    _heartbeatCallbacks.remove(nodeId);
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────

  /// Cancels the receive subscription and releases resources.
  ///
  /// Must be called when this manager is no longer needed.
  void dispose() {
    _rxSub.cancel();
    _nodeStates.clear();
    _heartbeatCallbacks.clear();
  }

  // ── Private helpers ──────────────────────────────────────────────────────

  Future<void> _sendCommand(NmtCommand command, int nodeId) {
    final frame = CanMessage(
      cobId: CobId.nmtBase,
      data: Uint8List.fromList([command.byte, nodeId]),
    );
    return _adapter.send(frame);
  }

  void _onFrame(CanMessage msg) {
    // Heartbeat / boot-up frames are on COB-IDs 0x701–0x77F.
    if (msg.cobId < CobId.heartbeatBase + 1 ||
        msg.cobId > CobId.heartbeatBase + 127) {
      return;
    }
    if (msg.data.isEmpty) return;

    final nodeId = msg.cobId - CobId.heartbeatBase;
    final state = NmtStateExt.fromByte(msg.data[0]);

    _nodeStates[nodeId] = state;
    _heartbeatCallbacks[nodeId]?.call(nodeId, state);
  }
}
