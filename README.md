# canopen_client

[![pub package](https://img.shields.io/pub/v/canopen_client.svg)](https://pub.dev/packages/canopen_client)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-android%20%7C%20linux%20%7C%20macos%20%7C%20windows-brightgreen)

A **CANopen master/client** library for Flutter.

Implements the core services of CiA 301 and CiA 305 over a USB-CANFD adapter
([can_usb](https://pub.dev/packages/can_usb)), with a single, easy-to-use
`CanOpenSimple` facade and fully injectable hardware abstraction for testing.

---

## Features

| Protocol | What is supported |
|---|---|
| **SDO** | Expedited and segmented upload/download; typed helpers for `u8`, `u16`, `u32`, `f32`, `f64`, `String` |
| **NMT** | Start, Stop, Pre-Operational, Reset Node, Reset Communication; heartbeat consumer with per-node callbacks |
| **PDO** | Transmit and receive frames; multiple callbacks per COB-ID |
| **SYNC** | Send SYNC with optional counter (1–240); incoming SYNC callbacks |
| **EMCY** | Per-node handler registration; ring-buffer message history |
| **LSS** | Global/selective switch; inquire Vendor-ID/Product-Code/Revision/Serial; configure Node-ID and bit-timing; store to NVM; Fastscan discovery |

---

## Getting started

### Prerequisites

- Flutter ≥ 3.22.0 / Dart ≥ 3.5.0
- A `can_usb`-compatible USB-CANFD adapter (Windows, Linux, macOS, Android)

### Installation

Add to `pubspec.yaml`:

```yaml
dependencies:
  canopen_client: ^0.1.0
```

Then run:

```sh
flutter pub get
```

---

## Usage

### Quick start

```dart
import 'package:canopen_client/canopen_client.dart';

future<void> main() async {
  final canopen = CanOpenSimple();

  final ports = await canopen.listPorts();
  await canopen.connect(ports.first, BusSpeed.baud1M);

  final deviceType = await canopen.sdoReadU32(5, 0x1000, 0);
  print('Device type: 0x${deviceType.toRadixString(16)}');

  await canopen.disconnect();
  canopen.dispose();
}
```

### SDO — reading and writing object dictionary entries

```dart
// Typed read helpers
final u8  = await canopen.sdoReadU8 (nodeId, 0x6000, 0);
final u16 = await canopen.sdoReadU16(nodeId, 0x6001, 0);
final u32 = await canopen.sdoReadU32(nodeId, 0x1000, 0);
final f32 = await canopen.sdoReadF32(nodeId, 0x6002, 0);
final str = await canopen.sdoReadString(nodeId, 0x1008, 0);

// Typed write helpers
await canopen.sdoWriteU8 (nodeId, 0x6200, 0, 0xFF);
await canopen.sdoWriteU16(nodeId, 0x1017, 0, 1000);
await canopen.sdoWriteU32(nodeId, 0x1400, 1, 0x205);
await canopen.sdoWriteF32(nodeId, 0x6003, 0,  3.14);
```

### NMT — node lifecycle

```dart
await canopen.nmtStart(nodeId);              // Operational
await canopen.nmtEnterPreOperational(nodeId);
await canopen.nmtResetNode(nodeId);

// Heartbeat consumer
canopen.registerHeartbeatCallback(nodeId, (id, state) {
  print('Node $id is $state');
});

final state = canopen.getNodeState(nodeId);  // NmtState.*
```

### PDO — process data

```dart
// Transmit a PDO
await canopen.sendPdo(0x205, Uint8List.fromList([0x01, 0x00]));

// Receive a PDO
canopen.registerPdoCallback(0x185, (data) {
  print('Received: $data');
});

canopen.unregisterAllPdoCallbacks(0x185);
```

### SYNC

```dart
canopen.setSyncCounterEnabled(true);
await canopen.sendSync();             // sends counter byte 1, 2, 3 …
canopen.resetSyncCounter();           // resets to 0

canopen.registerSyncCallback((counter) => print('SYNC $counter'));
```

### EMCY — emergency messages

```dart
canopen.registerEmcyHandler(nodeId, (emcy) {
  print('EMCY node=${emcy.nodeId} '
        'code=0x${emcy.errorCode.toRadixString(16)} '
        'reg=0x${emcy.errorRegister.toRadixString(16)}');
});

final recent = canopen.getRecentEmcy(nodeId);   // List<EmcyMessage>
canopen.clearEmcyHistory(nodeId);
```

### LSS — Layer Setting Services (CiA 305)

```dart
// Switch all slaves to configuration mode
await canopen.lssSwitchStateGlobal(LssMode.configuration);

// Inquire identity
final vendorId = await canopen.lssInquireVendorId();
final serial   = await canopen.lssInquireSerialNumber();

// Configure node-ID and store
final err = await canopen.lssConfigureNodeId(10);
if (err == LssError.success) {
  await canopen.lssStoreConfiguration();
}

// Fastscan — discover all unconfigured slaves
final devices = await canopen.lssFastscan();
for (final addr in devices) {
  print('Found: $addr');
}

await canopen.lssSwitchStateGlobal(LssMode.operation);
```

---

## API overview

### `CanOpenSimple`

| Category | Methods |
|---|---|
| Lifecycle | `listPorts()`, `connect()`, `disconnect()`, `dispose()` |
| SDO reads | `sdoRead()`, `sdoReadU8/U16/U32/F32/F64/String()` |
| SDO writes | `sdoWrite()`, `sdoWriteU8/U16/U32/F32/F64()` |
| NMT | `nmtStart/Stop/EnterPreOperational/ResetNode/ResetCommunication()`, `getNodeState()`, `register/unregisterHeartbeatCallback()` |
| PDO | `sendPdo()`, `register/unregisterAllPdoCallbacks()` |
| SYNC | `sendSync()`, `setSyncCounterEnabled()`, `resetSyncCounter()`, `register/unregisterSyncCallback()` |
| EMCY | `register/unregisterEmcyHandler()`, `getRecentEmcy()`, `clearEmcyHistory()` |
| LSS | `lssSwitchStateGlobal/Selective()`, `lssInquireVendorId/ProductCode/RevisionNumber/SerialNumber()`, `lssConfigureNodeId/BitTiming()`, `lssActivateBitTiming()`, `lssStoreConfiguration()`, `lssFastscan()` |

All methods throw `StateError` if called before `connect()`.

---

## Hardware requirements

The default backend uses the [`can_usb`](https://pub.dev/packages/can_usb) package,
which supports USB-CANFD adapters on Windows, Linux, macOS, and Android.

For custom hardware or testing, implement `ICanAdapter` and pass it to
`CanOpenSimple(adapter: myAdapter)`:  

```dart
final canopen = CanOpenSimple(adapter: MyCustomAdapter());
```

---

## Supported platforms

| Platform | Status |
|---|---|
| Windows | ✅ |
| Linux   | ✅ |
| macOS   | ✅ |
| Android | ✅ |
| iOS / Web | ❌ (no `can_usb` support) |

---

## Contributing

Pull requests are welcome. Please open an issue first to discuss major changes.
All contributions must pass `dart analyze`, `dart format`, and `flutter test` with
no regressions.

---

## License

MIT — see [LICENSE](LICENSE).
