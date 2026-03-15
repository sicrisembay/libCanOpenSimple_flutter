/// CANopen protocol enums and type extensions.
library;

// ── Bus Speed ────────────────────────────────────────────────────────────────

/// CAN bus bit rates supported by the CANopen client.
enum BusSpeed {
  /// 10 kbps
  baud10k,

  /// 20 kbps
  baud20k,

  /// 50 kbps
  baud50k,

  /// 100 kbps
  baud100k,

  /// 125 kbps (default for many CANopen networks)
  baud125k,

  /// 250 kbps
  baud250k,

  /// 500 kbps
  baud500k,

  /// 800 kbps
  baud800k,

  /// 1 Mbps (common in high-speed CANopen networks)
  baud1M,
}

/// Extension providing the numeric kbps value for each [BusSpeed].
extension BusSpeedExt on BusSpeed {
  /// Returns the bus speed in kbps.
  int get kbps => switch (this) {
        BusSpeed.baud10k => 10,
        BusSpeed.baud20k => 20,
        BusSpeed.baud50k => 50,
        BusSpeed.baud100k => 100,
        BusSpeed.baud125k => 125,
        BusSpeed.baud250k => 250,
        BusSpeed.baud500k => 500,
        BusSpeed.baud800k => 800,
        BusSpeed.baud1M => 1000,
      };
}

// ── NMT State ────────────────────────────────────────────────────────────────

/// CANopen NMT node state (CiA 301 §7.3.2).
enum NmtState {
  /// Node has just booted (heartbeat byte 0x00).
  bootUp,

  /// Node is stopped (heartbeat byte 0x04).
  stopped,

  /// Node is in operational state (heartbeat byte 0x05).
  operational,

  /// Node is in pre-operational state (heartbeat byte 0x7F).
  preOperational,

  /// State is unknown (no heartbeat received yet).
  unknown,
}

/// Extension that parses the single heartbeat state byte into [NmtState].
extension NmtStateExt on NmtState {
  /// Returns the NMT state byte transmitted in heartbeat messages.
  int get stateByte => switch (this) {
        NmtState.bootUp => 0x00,
        NmtState.stopped => 0x04,
        NmtState.operational => 0x05,
        NmtState.preOperational => 0x7F,
        NmtState.unknown => 0xFF,
      };

  /// Parses a raw heartbeat state byte to an [NmtState].
  static NmtState fromByte(int byte) => switch (byte) {
        0x00 => NmtState.bootUp,
        0x04 => NmtState.stopped,
        0x05 => NmtState.operational,
        0x7F => NmtState.preOperational,
        _ => NmtState.unknown,
      };
}

// ── NMT Command ──────────────────────────────────────────────────────────────

/// NMT command sent from master to a node (CiA 301 §7.3.3).
enum NmtCommand {
  /// Transition node to Operational state.
  start,

  /// Transition node to Stopped state.
  stop,

  /// Transition node to Pre-Operational state.
  enterPreOperational,

  /// Reset the node application.
  resetNode,

  /// Reset only the node's communication layer.
  resetCommunication,
}

/// Extension providing the command byte for each [NmtCommand].
extension NmtCommandExt on NmtCommand {
  /// Returns the NMT command byte (first byte of the NMT frame).
  int get byte => switch (this) {
        NmtCommand.start => 0x01,
        NmtCommand.stop => 0x02,
        NmtCommand.enterPreOperational => 0x80,
        NmtCommand.resetNode => 0x81,
        NmtCommand.resetCommunication => 0x82,
      };
}

// ── LSS Mode ─────────────────────────────────────────────────────────────────

/// LSS (Layer Setting Services) operating mode (CiA 305).
enum LssMode {
  /// Normal operating mode — LSS slaves do not respond to configuration.
  operation,

  /// Configuration mode — LSS slaves accept configuration commands.
  configuration,
}

/// Extension providing the mode byte for each [LssMode].
extension LssModeExt on LssMode {
  /// Returns the LSS mode byte used in the Switch State Global command.
  int get byte => switch (this) {
        LssMode.operation => 0x00,
        LssMode.configuration => 0x01,
      };
}
