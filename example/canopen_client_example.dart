// ignore_for_file: avoid_print

/// A standalone example demonstrating the canopen_client package.
///
/// Run against a real CANopen network:
///   dart run example/canopen_client_example.dart
///
/// The example assumes at least one CANopen node is reachable at node-ID 5.
/// All API calls are wrapped in try/catch so the program exits gracefully
/// when no hardware is attached.
library;

import 'dart:typed_data';

import 'package:canopen_client/canopen_client.dart';

Future<void> main() async {
  // ── 1. Create facade ────────────────────────────────────────────────────
  final canopen = CanOpenSimple();

  // ── 2. Select port ──────────────────────────────────────────────────────
  final ports = await canopen.listPorts();
  print('Available CAN ports: $ports');

  if (ports.isEmpty) {
    print('No CAN adapter found. Exiting.');
    canopen.dispose();
    return;
  }

  // ── 3. Connect at 1 Mbit/s ──────────────────────────────────────────────
  try {
    await canopen.connect(ports.first, BusSpeed.baud1M);
    print('Connected to ${ports.first} at 1 Mbit/s.');
  } on HardwareException catch (e) {
    print('Could not open adapter: $e');
    canopen.dispose();
    return;
  }

  const nodeId = 5;

  // ── 4. SDO reads & writes ───────────────────────────────────────────────
  try {
    // Read device type (mandatory object 0x1000-00).
    final deviceType = await canopen.sdoReadU32(nodeId, 0x1000, 0);
    print(
        'Device type: 0x${deviceType.toRadixString(16).toUpperCase().padLeft(8, '0')}');

    // Read device name string (0x1008-00).
    final name = await canopen.sdoReadString(nodeId, 0x1008, 0);
    print('Device name: $name');

    // Set heartbeat producer time to 1000 ms (0x1017-00).
    await canopen.sdoWriteU16(nodeId, 0x1017, 0, 1000);
    print('Heartbeat producer set to 1000 ms.');
  } on SdoAbortException catch (e) {
    print('SDO abort: $e');
  } on CanOpenTimeoutException catch (e) {
    print('SDO timeout: $e');
  }

  // ── 5. NMT ──────────────────────────────────────────────────────────────
  try {
    await canopen.nmtStart(nodeId);
    print('Node $nodeId set to Operational.');
  } on CanOpenTimeoutException catch (e) {
    print('NMT timeout: $e');
  }

  // Register heartbeat callback to track node state changes.
  canopen.registerHeartbeatCallback(nodeId, (id, state) {
    print('Heartbeat from node $id: $state');
  });

  // ── 6. PDO ──────────────────────────────────────────────────────────────
  // Register a receive PDO callback.  COB-ID 0x185 = TPDO1 of node 5.
  canopen.registerPdoCallback(0x185, (data) {
    final hex = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    print('PDO 0x185 received: $hex');
  });

  // Transmit a PDO to node 5 (RPDO1 default COB-ID = 0x205).
  try {
    await canopen.sendPdo(0x205,
        Uint8List.fromList([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]));
  } on CanOpenException catch (_) {
    // May throw if not supported by node — ignore for demo.
  }

  // ── 7. SYNC ─────────────────────────────────────────────────────────────
  canopen.setSyncCounterEnabled(true);
  await canopen.sendSync();
  print('SYNC sent (counter enabled).');

  canopen.registerSyncCallback((counter) {
    print('Incoming SYNC counter: $counter');
  });

  // ── 8. EMCY ─────────────────────────────────────────────────────────────
  canopen.registerEmcyHandler(nodeId, (emcy) {
    print('EMCY from node ${emcy.nodeId}: '
        'code=0x${emcy.errorCode.toRadixString(16).toUpperCase().padLeft(4, '0')}, '
        'reg=0x${emcy.errorRegister.toRadixString(16).padLeft(2, '0')}');
  });

  // ── 9. LSS (optional) ───────────────────────────────────────────────────
  try {
    await canopen.lssSwitchStateGlobal(LssMode.configuration);

    final serial = await canopen.lssInquireSerialNumber();
    print('LSS serial number: 0x${serial.toRadixString(16).toUpperCase()}');

    // Discover unconfigured nodes using Fastscan.
    final found = await canopen.lssFastscan(
      timeout: const Duration(seconds: 3),
      probeTimeout: const Duration(milliseconds: 200),
    );
    print('Fastscan found ${found.length} unconfigured node(s).');
    for (final addr in found) {
      print('  $addr');
    }
  } on CanOpenTimeoutException catch (_) {
    // No slave in LSS configuration mode — continue.
  } finally {
    try {
      await canopen.lssSwitchStateGlobal(LssMode.operation);
    } on CanOpenTimeoutException catch (_) {}
  }

  // ── 10. Clean up ─────────────────────────────────────────────────────────
  await canopen.disconnect();
  canopen.dispose();
  print('Done.');
}
