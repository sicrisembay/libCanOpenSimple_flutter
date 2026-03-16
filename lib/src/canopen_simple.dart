/// Top-level CanOpenSimple facade — composes all CANopen managers into a
/// single convenient entry point.
library;

import 'dart:typed_data';

import 'package:canopen_client/src/canopen/emcy.dart';
import 'package:canopen_client/src/canopen/lss.dart';
import 'package:canopen_client/src/canopen/nmt.dart';
import 'package:canopen_client/src/canopen/pdo.dart';
import 'package:canopen_client/src/canopen/sdo.dart';
import 'package:canopen_client/src/canopen/sync.dart';
import 'package:canopen_client/src/canopen/types.dart';
import 'package:canopen_client/src/errors.dart';
import 'package:canopen_client/src/hardware/can_usb_adapter.dart';
import 'package:canopen_client/src/hardware/i_can_adapter.dart';

// ── CanOpenSimple ─────────────────────────────────────────────────────────────

/// All-in-one CANopen master/client.
///
/// Composes [NmtManager], [SdoClient], [PdoManager], [SyncManager],
/// [EmcyManager] and [LssClient] behind a single, easy-to-use API.
///
/// ## Typical usage
/// ```dart
/// final canopen = CanOpenSimple();
///
/// // List serial ports and connect.
/// final ports = await canopen.listPorts();
/// await canopen.connect(ports.first, BusSpeed.baud1M);
///
/// // Read & write object dictionary entries.
/// final type = await canopen.sdoReadU32(5, 0x1000, 0);
/// await canopen.sdoWriteU16(5, 0x1017, 0, 1000);
///
/// // NMT control.
/// await canopen.nmtStart(5);
///
/// // PDO callbacks.
/// canopen.registerPdoCallback(0x185, (data) => print(data));
///
/// // Clean up.
/// await canopen.disconnect();
/// canopen.dispose();
/// ```
class CanOpenSimple {
  /// Creates a [CanOpenSimple] instance.
  ///
  /// An optional [adapter] can be supplied for testing or when using a custom
  /// hardware backend.  If omitted a [CanUsbAdapter] is used.
  CanOpenSimple({ICanAdapter? adapter}) : _adapter = adapter ?? CanUsbAdapter();

  final ICanAdapter _adapter;

  NmtManager? _nmt;
  SdoClient? _sdo;
  PdoManager? _pdo;
  SyncManager? _sync;
  EmcyManager? _emcy;
  LssClient? _lss;

  bool _connected = false;

  /// Returns `true` when [connect] has been called and [disconnect] has not
  /// yet been called.
  bool get isConnected => _connected;

  // ── Connection lifecycle ───────────────────────────────────────────────────

  /// Returns the list of available serial port names.
  Future<List<String>> listPorts() => _adapter.listPorts();

  /// Connects to the CAN adapter on [port] at [speed] and initialises all
  /// protocol managers.
  ///
  /// Throws [HardwareException] if the adapter cannot open the port.
  Future<void> connect(String port, BusSpeed speed) async {
    await _adapter.connect(port, speed);
    _nmt = NmtManager(_adapter);
    _sdo = SdoClient(_adapter);
    _pdo = PdoManager(_adapter);
    _sync = SyncManager(_adapter);
    _emcy = EmcyManager(_adapter);
    _lss = LssClient(_adapter);
    _connected = true;
  }

  /// Disconnects from the CAN adapter and disposes all protocol managers.
  Future<void> disconnect() async {
    _disposeManagers();
    await _adapter.disconnect();
    _connected = false;
  }

  /// Releases all resources including the underlying [ICanAdapter].
  ///
  /// Call this when the [CanOpenSimple] instance will no longer be used.
  void dispose() {
    _disposeManagers();
    _adapter.dispose();
  }

  // ── SDO ───────────────────────────────────────────────────────────────────

  /// Reads a remote object dictionary entry via SDO upload.
  ///
  /// Handles expedited (≤ 4 bytes) and segmented (> 4 bytes) transfers
  /// transparently.
  ///
  /// [nodeId]   — CANopen node ID (1–127).
  /// [index]    — Object dictionary index (e.g. `0x1000`).
  /// [subIndex] — Sub-index (e.g. `0x00`).
  /// [timeout]  — Maximum wait time per segment (default 1 s).
  ///
  /// Throws [SdoAbortException] if the remote node aborts the transfer.
  /// Throws [CanOpenTimeoutException] if no response is received in time.
  Future<Uint8List> sdoRead(
    int nodeId,
    int index,
    int subIndex, {
    Duration timeout = const Duration(seconds: 1),
  }) =>
      _requireConnected(
          () => _sdo!.sdoRead(nodeId, index, subIndex, timeout: timeout));

  /// Writes a value to a remote object dictionary entry via SDO download.
  ///
  /// Handles expedited (≤ 4 bytes) and segmented (> 4 bytes) transfers
  /// transparently.
  ///
  /// [nodeId]   — CANopen node ID (1–127).
  /// [index]    — Object dictionary index.
  /// [subIndex] — Sub-index.
  /// [data]     — Raw bytes to write.
  /// [timeout]  — Maximum wait time per segment (default 1 s).
  ///
  /// Throws [SdoAbortException] if the remote node aborts the transfer.
  /// Throws [CanOpenTimeoutException] if no response is received in time.
  Future<void> sdoWrite(
    int nodeId,
    int index,
    int subIndex,
    Uint8List data, {
    Duration timeout = const Duration(seconds: 1),
  }) =>
      _requireConnected(() =>
          _sdo!.sdoWrite(nodeId, index, subIndex, data, timeout: timeout));

  /// Reads an 8-bit unsigned integer from the remote object dictionary.
  Future<int> sdoReadU8(int nodeId, int index, int subIndex,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(
          () => _sdo!.sdoReadU8(nodeId, index, subIndex, timeout: timeout));

  /// Reads a 16-bit unsigned integer from the remote object dictionary.
  Future<int> sdoReadU16(int nodeId, int index, int subIndex,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(
          () => _sdo!.sdoReadU16(nodeId, index, subIndex, timeout: timeout));

  /// Reads a 32-bit unsigned integer from the remote object dictionary.
  Future<int> sdoReadU32(int nodeId, int index, int subIndex,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(
          () => _sdo!.sdoReadU32(nodeId, index, subIndex, timeout: timeout));

  /// Reads a 32-bit IEEE 754 float from the remote object dictionary.
  Future<double> sdoReadF32(int nodeId, int index, int subIndex,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(
          () => _sdo!.sdoReadF32(nodeId, index, subIndex, timeout: timeout));

  /// Reads a 64-bit IEEE 754 double from the remote object dictionary.
  Future<double> sdoReadF64(int nodeId, int index, int subIndex,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(
          () => _sdo!.sdoReadF64(nodeId, index, subIndex, timeout: timeout));

  /// Reads a UTF-8 string from the remote object dictionary.
  Future<String> sdoReadString(int nodeId, int index, int subIndex,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(
          () => _sdo!.sdoReadString(nodeId, index, subIndex, timeout: timeout));

  /// Writes an 8-bit unsigned integer to the remote object dictionary.
  Future<void> sdoWriteU8(int nodeId, int index, int subIndex, int value,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() =>
          _sdo!.sdoWriteU8(nodeId, index, subIndex, value, timeout: timeout));

  /// Writes a 16-bit unsigned integer to the remote object dictionary.
  Future<void> sdoWriteU16(int nodeId, int index, int subIndex, int value,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() =>
          _sdo!.sdoWriteU16(nodeId, index, subIndex, value, timeout: timeout));

  /// Writes a 32-bit unsigned integer to the remote object dictionary.
  Future<void> sdoWriteU32(int nodeId, int index, int subIndex, int value,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() =>
          _sdo!.sdoWriteU32(nodeId, index, subIndex, value, timeout: timeout));

  /// Writes a 32-bit IEEE 754 float to the remote object dictionary.
  Future<void> sdoWriteF32(int nodeId, int index, int subIndex, double value,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() =>
          _sdo!.sdoWriteF32(nodeId, index, subIndex, value, timeout: timeout));

  /// Writes a 64-bit IEEE 754 double to the remote object dictionary.
  Future<void> sdoWriteF64(int nodeId, int index, int subIndex, double value,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() =>
          _sdo!.sdoWriteF64(nodeId, index, subIndex, value, timeout: timeout));

  // ── NMT ───────────────────────────────────────────────────────────────────

  /// Sends an NMT Start Remote Node command to [nodeId] (or all nodes if 0).
  Future<void> nmtStart(int nodeId,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() => _nmt!.nmtStart(nodeId));

  /// Sends an NMT Stop Remote Node command to [nodeId] (or all nodes if 0).
  Future<void> nmtStop(int nodeId) =>
      _requireConnected(() => _nmt!.nmtStop(nodeId));

  /// Sends an NMT Enter Pre-Operational command to [nodeId].
  Future<void> nmtEnterPreOperational(int nodeId) =>
      _requireConnected(() => _nmt!.nmtEnterPreOperational(nodeId));

  /// Sends an NMT Reset Node command to [nodeId].
  Future<void> nmtResetNode(int nodeId) =>
      _requireConnected(() => _nmt!.nmtResetNode(nodeId));

  /// Sends an NMT Reset Communication command to [nodeId].
  Future<void> nmtResetCommunication(int nodeId) =>
      _requireConnected(() => _nmt!.nmtResetCommunication(nodeId));

  /// Returns the last-known [NmtState] for [nodeId].
  ///
  /// Returns [NmtState.unknown] if no heartbeat has been received yet.
  NmtState getNodeState(int nodeId) =>
      _requireConnected(() => _nmt!.getNodeState(nodeId));

  /// Registers [callback] to be called whenever a heartbeat is received from
  /// [nodeId].
  ///
  /// The callback receives the node ID and its new [NmtState].
  void registerHeartbeatCallback(
    int nodeId,
    void Function(int nodeId, NmtState state) callback,
  ) =>
      _requireConnected(
          () => _nmt!.registerHeartbeatCallback(nodeId, callback));

  /// Removes the heartbeat callback registered for [nodeId].
  void unregisterHeartbeatCallback(int nodeId) =>
      _requireConnected(() => _nmt!.unregisterHeartbeatCallback(nodeId));

  // ── PDO ───────────────────────────────────────────────────────────────────

  /// Transmits a PDO frame with [cobId] and [data] payload (1–8 bytes).
  ///
  /// Throws [CanOpenException] if data length is out of range.
  Future<void> sendPdo(int cobId, Uint8List data) =>
      _requireConnected(() => _pdo!.sendPdo(cobId, data));

  /// Registers [callback] to be called whenever a frame with [cobId] arrives.
  ///
  /// Multiple callbacks per COB-ID are supported.
  void registerPdoCallback(int cobId, void Function(Uint8List data) callback) =>
      _requireConnected(() => _pdo!.registerPdoCallback(cobId, callback));

  /// Removes all callbacks registered for [cobId].
  void unregisterAllPdoCallbacks(int cobId) =>
      _requireConnected(() => _pdo!.unregisterAllCallbacks(cobId));

  // ── SYNC ──────────────────────────────────────────────────────────────────

  /// Transmits a SYNC message.
  ///
  /// If the sync counter is enabled (see [setSyncCounterEnabled]) a 1-byte
  /// counter (1–240) is included; otherwise a 0-byte frame is sent.
  Future<void> sendSync() => _requireConnected(() => _sync!.sendSync());

  /// Enables or disables the SYNC counter.
  void setSyncCounterEnabled(bool enabled) =>
      _requireConnected(() => _sync!.setSyncCounterEnabled(enabled));

  /// Resets the SYNC counter so the next [sendSync] starts from 1.
  void resetSyncCounter() => _requireConnected(() => _sync!.resetCounter());

  /// Registers [callback] to be called on every incoming SYNC frame.
  ///
  /// The argument is the counter byte, or `null` when no counter byte is
  /// present.
  void registerSyncCallback(void Function(int? counter) callback) =>
      _requireConnected(() => _sync!.registerSyncCallback(callback));

  /// Removes a previously registered sync [callback].
  void unregisterSyncCallback(void Function(int? counter) callback) =>
      _requireConnected(() => _sync!.unregisterSyncCallback(callback));

  // ── EMCY ──────────────────────────────────────────────────────────────────

  /// Registers [handler] to be called whenever an EMCY frame from [nodeId]
  /// is received.
  void registerEmcyHandler(
    int nodeId,
    void Function(EmcyMessage message) handler,
  ) =>
      _requireConnected(() => _emcy!.registerEmcyHandler(nodeId, handler));

  /// Removes the EMCY handler for [nodeId].
  void unregisterEmcyHandler(int nodeId) =>
      _requireConnected(() => _emcy!.unregisterEmcyHandler(nodeId));

  /// Returns the most recent [count] EMCY messages received from [nodeId].
  List<EmcyMessage> getRecentEmcy(int nodeId, {int count = 10}) =>
      _requireConnected(() => _emcy!.getRecentEmcy(nodeId, count: count));

  /// Clears the EMCY message history for [nodeId].
  void clearEmcyHistory(int nodeId) =>
      _requireConnected(() => _emcy!.clearHistory(nodeId));

  // ── LSS ───────────────────────────────────────────────────────────────────

  /// Switches all LSS slaves to [mode] simultaneously (global switch).
  Future<void> lssSwitchStateGlobal(LssMode mode,
          {Duration timeout = const Duration(milliseconds: 100)}) =>
      _requireConnected(
          () => _lss!.lssSwitchStateGlobal(mode, timeout: timeout));

  /// Switches a single LSS slave identified by [address] into configuration
  /// mode (selective switch).
  ///
  /// Throws [CanOpenTimeoutException] if no response arrives within [timeout].
  Future<void> lssSwitchStateSelective(LssAddress address,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(
          () => _lss!.lssSwitchStateSelective(address, timeout: timeout));

  /// Reads the Vendor-ID from the selected LSS slave.
  Future<int> lssInquireVendorId(
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() => _lss!.lssInquireVendorId(timeout: timeout));

  /// Reads the Product-Code from the selected LSS slave.
  Future<int> lssInquireProductCode(
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() => _lss!.lssInquireProductCode(timeout: timeout));

  /// Reads the Revision-Number from the selected LSS slave.
  Future<int> lssInquireRevisionNumber(
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() => _lss!.lssInquireRevisionNumber(timeout: timeout));

  /// Reads the Serial-Number from the selected LSS slave.
  Future<int> lssInquireSerialNumber(
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() => _lss!.lssInquireSerialNumber(timeout: timeout));

  /// Reads the current Node-ID from the selected LSS slave.
  ///
  /// Returns 0xFF if the slave is unconfigured.
  Future<int> lssInquireNodeId(
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() => _lss!.lssInquireNodeId(timeout: timeout));

  /// Broadcasts a Vendor-ID inquiry and collects all responses until
  /// [timeout] expires (one response per slave on the network).
  Future<List<int>> lssInquireVendorIds(
          {Duration timeout = const Duration(seconds: 2)}) =>
      _requireConnected(() => _lss!.lssInquireVendorIds(timeout: timeout));

  /// Broadcasts a Product-Code inquiry and collects all responses until
  /// [timeout] expires.
  Future<List<int>> lssInquireProductCodes(
          {Duration timeout = const Duration(seconds: 2)}) =>
      _requireConnected(() => _lss!.lssInquireProductCodes(timeout: timeout));

  /// Broadcasts a Revision-Number inquiry and collects all responses until
  /// [timeout] expires.
  Future<List<int>> lssInquireRevisionNumbers(
          {Duration timeout = const Duration(seconds: 2)}) =>
      _requireConnected(
          () => _lss!.lssInquireRevisionNumbers(timeout: timeout));

  /// Broadcasts a Serial-Number inquiry and collects all responses until
  /// [timeout] expires.
  Future<List<int>> lssInquireSerialNumbers(
          {Duration timeout = const Duration(seconds: 2)}) =>
      _requireConnected(() => _lss!.lssInquireSerialNumbers(timeout: timeout));

  /// Configures the node-ID of the selected LSS slave.
  ///
  /// Returns [LssError.success] on acknowledgement.
  Future<LssError> lssConfigureNodeId(int nodeId,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(
          () => _lss!.lssConfigureNodeId(nodeId, timeout: timeout));

  /// Configures the bit-timing parameters of the selected LSS slave.
  Future<LssError> lssConfigureBitTiming(int tableSelector, int tableIndex,
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() => _lss!
          .lssConfigureBitTiming(tableSelector, tableIndex, timeout: timeout));

  /// Activates the new bit-timing parameters (fire-and-forget).
  Future<void> lssActivateBitTiming(int switchDelayMs) =>
      _requireConnected(() => _lss!.lssActivateBitTiming(switchDelayMs));

  /// Stores the current configuration to NVM on the selected LSS slave.
  Future<LssError> lssStoreConfiguration(
          {Duration timeout = const Duration(seconds: 1)}) =>
      _requireConnected(() => _lss!.lssStoreConfiguration(timeout: timeout));

  /// Discovers all unconfigured LSS slaves using a Fastscan broadcast.
  ///
  /// Returns a list of [LssAddress] for each discovered device.
  Future<List<LssAddress>> lssFastscan({
    Duration timeout = const Duration(seconds: 5),
    Duration probeTimeout = const Duration(milliseconds: 200),
    int startNodeId = 1,
  }) =>
      _requireConnected(() => _lss!.lssFastscan(
            timeout: timeout,
            probeTimeout: probeTimeout,
            startNodeId: startNodeId,
          ));

  // ── Internal helpers ──────────────────────────────────────────────────────

  T _requireConnected<T>(T Function() fn) {
    if (!_connected) {
      throw StateError('CanOpenSimple is not connected. Call connect() first.');
    }
    return fn();
  }

  void _disposeManagers() {
    _nmt?.dispose();
    _sdo?.dispose();
    _pdo?.dispose();
    _sync?.dispose();
    _emcy?.dispose();
    _lss?.dispose();
    _nmt = null;
    _sdo = null;
    _pdo = null;
    _sync = null;
    _emcy = null;
    _lss = null;
  }
}
