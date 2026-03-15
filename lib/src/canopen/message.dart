/// CAN message model and COB-ID constants for the CANopen protocol.
library;

import 'dart:typed_data';

/// A single CAN frame carrying a CANopen message.
class CanMessage {
  /// Creates a [CanMessage].
  ///
  /// [cobId]  — 11-bit Communication Object Identifier.
  /// [data]   — Payload bytes (0–8 bytes for CAN Classic).
  /// [isRtr]  — `true` if this is a Remote Transmission Request frame.
  const CanMessage({
    required this.cobId,
    required this.data,
    this.isRtr = false,
  });

  /// 11-bit COB-ID.
  final int cobId;

  /// Payload (0–8 bytes).
  final Uint8List data;

  /// Whether this is a Remote Transmission Request frame.
  final bool isRtr;

  @override
  String toString() =>
      'CanMessage(cobId: 0x${cobId.toRadixString(16).toUpperCase().padLeft(3, '0')}, '
      'data: [${data.map((b) => '0x${b.toRadixString(16).toUpperCase().padLeft(2, '0')}').join(', ')}], '
      'isRtr: $isRtr)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CanMessage &&
          cobId == other.cobId &&
          isRtr == other.isRtr &&
          _bytesEqual(data, other.data);

  @override
  int get hashCode => Object.hash(cobId, isRtr, Object.hashAll(data));

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Standard CANopen COB-ID base addresses (CiA 301).
///
/// For node-specific COB-IDs, add the node ID (1–127) to the base value.
/// Example: SDO transmit from node 5 → `CobId.sdoTxBase + 5` = `0x585`.
abstract class CobId {
  CobId._();

  /// NMT (Network Management) — always 0x000, no node offset.
  static const int nmtBase = 0x000;

  /// SYNC — always 0x080, no node offset.
  static const int syncBase = 0x080;

  /// EMCY (Emergency) base — add node ID (1–127).
  static const int emergBase = 0x080;

  /// TPDO1 (Transmit PDO 1) base — add node ID.
  static const int tpdo1Base = 0x180;

  /// RPDO1 (Receive PDO 1) base — add node ID.
  static const int rpdo1Base = 0x200;

  /// TPDO2 (Transmit PDO 2) base — add node ID.
  static const int tpdo2Base = 0x280;

  /// RPDO2 (Receive PDO 2) base — add node ID.
  static const int rpdo2Base = 0x300;

  /// TPDO3 (Transmit PDO 3) base — add node ID.
  static const int tpdo3Base = 0x380;

  /// RPDO3 (Receive PDO 3) base — add node ID.
  static const int rpdo3Base = 0x400;

  /// TPDO4 (Transmit PDO 4) base — add node ID.
  static const int tpdo4Base = 0x480;

  /// RPDO4 (Receive PDO 4) base — add node ID.
  static const int rpdo4Base = 0x500;

  /// SDO transmit (response from node to master) base — add node ID.
  static const int sdoTxBase = 0x580;

  /// SDO receive (request from master to node) base — add node ID.
  static const int sdoRxBase = 0x600;

  /// NMT Heartbeat / Boot-up base — add node ID.
  static const int heartbeatBase = 0x700;

  /// LSS slave → master response COB-ID.
  static const int lss = 0x7E4;

  /// LSS master → slave command COB-ID.
  static const int lssMaster = 0x7E5;

  // ── Typed helpers ──────────────────────────────────────────────────────

  /// Returns the Emergency COB-ID for [nodeId].
  static int emerg(int nodeId) => emergBase + nodeId;

  /// Returns the SDO transmit COB-ID for [nodeId] (node → master).
  static int sdoTx(int nodeId) => sdoTxBase + nodeId;

  /// Returns the SDO receive COB-ID for [nodeId] (master → node).
  static int sdoRx(int nodeId) => sdoRxBase + nodeId;

  /// Returns the Heartbeat COB-ID for [nodeId].
  static int heartbeat(int nodeId) => heartbeatBase + nodeId;

  /// Returns the TPDO1 COB-ID for [nodeId].
  static int tpdo1(int nodeId) => tpdo1Base + nodeId;

  /// Returns the RPDO1 COB-ID for [nodeId].
  static int rpdo1(int nodeId) => rpdo1Base + nodeId;

  /// Returns the TPDO2 COB-ID for [nodeId].
  static int tpdo2(int nodeId) => tpdo2Base + nodeId;

  /// Returns the RPDO2 COB-ID for [nodeId].
  static int rpdo2(int nodeId) => rpdo2Base + nodeId;
}
