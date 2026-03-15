# libCANopenSimple Flutter — Detailed Phase Execution Plan

> This document breaks down each phase from `MIGRATION_PLAN.md §11` into concrete tasks,
> files to create, code contracts, commands to run, and acceptance criteria.

---

## Phase 1 — Project Scaffold, Hardware Abstraction & Core Models

### Goals
Set up the Flutter package skeleton, wire in `can_usb`, define the hardware abstraction
interface, and implement the core `CanMessage` model that every other module depends on.

### Tasks

#### 1.1 — Create the Flutter package

```bash
flutter create --template=package canopen_client
cd canopen_client
```

Remove the auto-generated placeholder files (`lib/canopen_client.dart` content,
`test/canopen_client_test.dart`) — we will fill them in later phases.

#### 1.2 — Configure `pubspec.yaml`

Replace the generated `pubspec.yaml` with:

```yaml
name: canopen_client
description: >
  A CANopen master/client library for Flutter. Supports SDO, NMT, PDO,
  SYNC, EMCY and LSS protocols over a USB-CANFD adapter (via can_usb).
version: 0.1.0
homepage: https://github.com/<your-org>/canopen_client
repository: https://github.com/<your-org>/canopen_client

environment:
  sdk: '>=3.5.0 <4.0.0'
  flutter: '>=3.22.0'

platforms:
  android:
  linux:
  macos:
  windows:

dependencies:
  flutter:
    sdk: flutter
  can_usb: ^0.1.1
  synchronized: ^3.1.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^4.0.0
  mockito: ^5.4.0
  build_runner: ^2.4.0
```

Run:
```bash
flutter pub get
```

#### 1.3 — Add `analysis_options.yaml`

```yaml
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    - always_use_package_imports
    - avoid_print
    - prefer_final_fields
    - unawaited_futures
    - cancel_subscriptions
```

#### 1.4 — Create directory structure

```
lib/src/hardware/
lib/src/canopen/
```

#### 1.5 — Implement `CanMessage` model

**File:** `lib/src/canopen/message.dart`

- `class CanMessage` with fields: `cobId` (int), `data` (Uint8List), `isRtr` (bool).
- `abstract class CobId` with all standard base constants:
  - `nmtBase = 0x000`
  - `syncBase = 0x080`
  - `emergBase = 0x080` (+ nodeId)
  - `tpdo1Base = 0x180`, `rpdo1Base = 0x200`
  - `tpdo2Base = 0x280`, `rpdo2Base = 0x300`
  - `tpdo3Base = 0x380`, `rpdo3Base = 0x400`
  - `tpdo4Base = 0x480`, `rpdo4Base = 0x500`
  - `sdoTxBase = 0x580`
  - `sdoRxBase = 0x600`
  - `heartbeatBase = 0x700`
  - `lss = 0x7E4`
  - `lssMaster = 0x7E5`
- Helper: `static int emerg(int nodeId)`, `static int sdoTx(int nodeId)`, etc.

#### 1.6 — Implement enums & types

**File:** `lib/src/canopen/types.dart`

```dart
enum BusSpeed { baud10k, baud20k, baud50k, baud100k, baud125k,
                baud250k, baud500k, baud800k, baud1M }

enum NmtState { bootUp, stopped, operational, preOperational, unknown }

enum NmtCommand { start, stop, enterPreOperational, resetNode, resetCommunication }

enum LssMode { operation, configuration }

/// Extension to get kbps integer for each BusSpeed
extension BusSpeedExt on BusSpeed { int get kbps { … } }

/// Extension to get NMT command byte
extension NmtCommandExt on NmtCommand { int get byte { … } }
```

#### 1.7 — Implement error types

**File:** `lib/src/errors.dart`

```dart
class CanOpenException       implements Exception { … }
class SdoAbortException      extends CanOpenException { final int abortCode; … }
class CanOpenTimeoutException extends CanOpenException { … }
class LssException           extends CanOpenException { final int lssErrorCode; … }
class HardwareException      extends CanOpenException { … }
```

#### 1.8 — Implement utility helpers

**File:** `lib/src/utils.dart`

- `Uint8List encodeU16LE(int value)`
- `Uint8List encodeU32LE(int value)`
- `int decodeU16LE(Uint8List data, int offset)`
- `int decodeU32LE(Uint8List data, int offset)`
- `double decodeFloat32LE(Uint8List data, int offset)`
- `String decodeUtf8(Uint8List data)` (null-terminated safe)

#### 1.9 — Implement the abstract hardware interface

**File:** `lib/src/hardware/i_can_adapter.dart`

```dart
abstract class ICanAdapter {
  /// Stream of CAN frames received from the bus.
  Stream<CanMessage> get rxFrames;

  /// List available serial port names.
  Future<List<String>> listPorts();

  /// Open the serial port and start the FDCAN peripheral.
  Future<void> connect(String port, BusSpeed speed);

  /// Stop the FDCAN peripheral and close the serial port.
  Future<void> disconnect();

  /// Transmit a single CAN frame.
  Future<void> send(CanMessage message);

  /// Release all resources.
  void dispose();
}
```

#### 1.10 — Implement the `can_usb` concrete adapter

**File:** `lib/src/hardware/can_usb_adapter.dart`

- Wraps `CanusbDevice` from `can_usb`.
- Constructor accepts optional `ISerialTransport transport` for testing.
- `connect()`:
  1. `await device.connect(port)`
  2. `await device.canStart()`
- `disconnect()`:
  1. `await device.canStop()`
  2. `await device.disconnect()`
- `send(msg)` → builds `CanFrame(id: msg.cobId, frameType: CanFrameType.classic(), data: msg.data)`,
  calls `device.sendFrame(frame)`.
- `rxFrames` → `device.rxFrames.map((f) => CanMessage(cobId: f.id, data: f.data))`.
- `listPorts()` → `(await device.listAvailablePorts()).map((p) => p.name).toList()`.

#### 1.11 — Create the barrel export file

**File:** `lib/canopen_client.dart`

Export only public-facing symbols (add more as each phase completes):
```dart
export 'src/canopen/message.dart';
export 'src/canopen/types.dart';
export 'src/errors.dart';
export 'src/hardware/i_can_adapter.dart';
export 'src/hardware/can_usb_adapter.dart';
```

#### 1.12 — Write unit tests for Phase 1

**File:** `test/message_test.dart`
- COB-ID helper functions return correct values.

**File:** `test/utils_test.dart`
- Round-trip encode/decode for U16, U32, Float32.

**File:** `test/can_usb_adapter_test.dart`
- Mock `ISerialTransport`, verify `connect()` calls `canStart()`.
- Verify `send()` maps `CanMessage` → `CanFrame` correctly.
- Verify `rxFrames` maps `CanFrame` → `CanMessage` correctly.

### Commands
```bash
flutter pub run build_runner build --delete-conflicting-outputs  # generate mocks
flutter test
dart analyze
dart format --set-exit-if-changed .
```

### Acceptance Criteria
- [ ] `flutter create` package compiles with zero warnings.
- [ ] All Phase 1 unit tests pass (`flutter test`).
- [ ] `dart analyze` reports zero issues.
- [ ] `can_usb_adapter.dart` can be instantiated with a mock transport.

---

## Phase 2 — NMT Manager

### Goals
Implement NMT command sending and heartbeat monitoring. This is the simplest CANopen
protocol and a good validation that the hardware layer works end-to-end.

### Tasks

#### 2.1 — Implement `NmtManager`

**File:** `lib/src/canopen/nmt.dart`

Internal state:
```dart
final Map<int, NmtState> _nodeStates = {};
final Map<int, void Function(int, NmtState)> _heartbeatCallbacks = {};
late StreamSubscription<CanMessage> _rxSub;
```

Initialisation:
- Subscribe to `adapter.rxFrames`.
- For each frame where `cobId >= 0x701 && cobId <= 0x77F`:
  - Extract `nodeId = cobId - 0x700`.
  - Parse state byte → `NmtState`.
  - Update `_nodeStates[nodeId]`.
  - Call registered callback if present.

NMT command framing:
```
Byte 0: command byte
Byte 1: node-ID (0 = all nodes)
COB-ID: 0x000
```

NMT command byte values:
| Command | Byte |
|---|---|
| Start | 0x01 |
| Stop | 0x02 |
| Enter pre-operational | 0x80 |
| Reset node | 0x81 |
| Reset communication | 0x82 |

**Public API:**
```dart
Future<void> nmtStart(int nodeId);
Future<void> nmtStop(int nodeId);
Future<void> nmtEnterPreOperational(int nodeId);
Future<void> nmtResetNode(int nodeId);
Future<void> nmtResetCommunication(int nodeId);
NmtState getNodeState(int nodeId);  // returns NmtState.unknown if unseen
void registerHeartbeatCallback(int nodeId, void Function(int, NmtState) cb);
void unregisterHeartbeatCallback(int nodeId);
void dispose();  // cancel _rxSub
```

#### 2.2 — Write unit tests

**File:** `test/nmt_test.dart`

- Sending `nmtStart(5)` puts frame `[0x01, 0x05]` on COB-ID `0x000`.
- Sending `nmtStart(0)` (broadcast) puts frame `[0x01, 0x00]`.
- Pushing a heartbeat frame `cobId=0x705, data=[0x7F]` updates state to
  `NmtState.preOperational` and fires the registered callback.
- `getNodeState` returns `NmtState.unknown` for an unseen node.

#### 2.3 — Export from barrel

Add to `lib/canopen_client.dart`:
```dart
export 'src/canopen/nmt.dart';
```

### Commands
```bash
flutter pub run build_runner build --delete-conflicting-outputs
flutter test test/nmt_test.dart
dart analyze
```

### Acceptance Criteria
- [ ] All NMT unit tests pass.
- [ ] Heartbeat callback fires with correct `nodeId` and `NmtState`.
- [ ] `dispose()` cancels the stream subscription without error.

---

## Phase 3 — SDO Client (Expedited Transfers)

### Goals
Implement SDO expedited upload (read ≤ 4 bytes) and expedited download (write ≤ 4 bytes)
with per-node locking and timeout handling.

### Tasks

#### 3.1 — SDO frame constants

In `message.dart` or `sdo.dart` constants section:

| Symbol | Value | Description |
|---|---|---|
| `sdoInitDownloadReq` | 0x20 | Initiate download (write) |
| `sdoInitDownloadRsp` | 0x60 | Download response |
| `sdoInitUploadReq` | 0x40 | Initiate upload (read) |
| `sdoInitUploadRsp` | 0x40 | Upload response (expedited bit set) |
| `sdoAbort` | 0x80 | Abort transfer |

Expedited download request (8 bytes):
```
[0] = 0x23 | ((4 - n) << 2)   // n = data bytes (1–4), e=1, s=1
[1] = index low
[2] = index high
[3] = subIndex
[4..7] = data (little-endian, zero-padded)
```

Expedited upload request (8 bytes):
```
[0] = 0x40
[1] = index low
[2] = index high
[3] = subIndex
[4..7] = 0x00
```

#### 3.2 — Implement `SdoClient`

**File:** `lib/src/canopen/sdo.dart`

Internal per-node lock:
```dart
final Map<int, Lock> _locks = {};   // synchronized package
Lock _lockFor(int nodeId) => _locks.putIfAbsent(nodeId, Lock.new);
```

Pending transaction (one active per node):
```dart
Completer<Uint8List>? _pending;
StreamSubscription<CanMessage>? _pendingSub;
```

Core private method:
```dart
Future<Uint8List> _transact(int nodeId, Uint8List txData,
    {Duration timeout = const Duration(seconds: 1)}) async {
  await _lockFor(nodeId).synchronized(() async {
    // 1. subscribe to sdoTxBase + nodeId
    // 2. send txData on sdoRxBase + nodeId
    // 3. await Completer with Future.timeout
    // 4. cancel subscription
    // 5. check response command byte for abort (0x80)
  });
}
```

**Public API:**
```dart
Future<Uint8List> sdoRead(int nodeId, int index, int subIndex,
    {Duration timeout = const Duration(seconds: 1)});

Future<void> sdoWrite(int nodeId, int index, int subIndex, Uint8List data,
    {Duration timeout = const Duration(seconds: 1)});

// Typed convenience wrappers (delegate to sdoRead/sdoWrite + ByteData parsing)
Future<int>    sdoReadU8(int nodeId, int index, int subIndex);
Future<int>    sdoReadU16(int nodeId, int index, int subIndex);
Future<int>    sdoReadU32(int nodeId, int index, int subIndex);
Future<double> sdoReadF32(int nodeId, int index, int subIndex);
Future<String> sdoReadString(int nodeId, int index, int subIndex);
Future<void>   sdoWriteU8(int nodeId, int index, int subIndex, int value);
Future<void>   sdoWriteU16(int nodeId, int index, int subIndex, int value);
Future<void>   sdoWriteU32(int nodeId, int index, int subIndex, int value);
Future<void>   sdoWriteF32(int nodeId, int index, int subIndex, double value);
```

Error handling:
- If response byte is `0x80`, extract 4-byte abort code and throw `SdoAbortException`.
- If no response within `timeout`, throw `CanOpenTimeoutException`.

#### 3.3 — Write unit tests

**File:** `test/sdo_test.dart`

- `sdoReadU8(5, 0x1001, 0)` sends correct expedited upload request frame.
- Simulated abort response `0x80` raises `SdoAbortException` with correct code.
- `sdoWriteU16(5, 0x1017, 0, 1000)` encodes 1000 as little-endian `[0xE8, 0x03]`.
- Timeout: no response within 100 ms raises `CanOpenTimeoutException`.
- Concurrent calls on same node are serialised (one completes before the next starts).

### Commands
```bash
flutter pub run build_runner build --delete-conflicting-outputs
flutter test test/sdo_test.dart
```

### Acceptance Criteria
- [ ] Expedited read/write unit tests pass.
- [ ] `SdoAbortException` carries the correct 4-byte abort code.
- [ ] `CanOpenTimeoutException` thrown after timeout expires.
- [ ] Concurrent SDO calls on the same node do not interleave.

---

## Phase 4 — SDO Client (Segmented Transfers & Typed Helpers)

### Goals
Extend the SDO client to handle segmented uploads and downloads (data > 4 bytes),
which are required for strings, arrays, and large object dictionary entries.

### Tasks

#### 4.1 — Segmented upload (read > 4 bytes)

Flow:
1. Send expedited upload request.
2. Receive initiate upload response — check `e` bit. If `e=0`, data > 4 bytes; `n` field
   gives indicated size (may be 0 if unknown).
3. Loop: send upload segment request (`0x60 | toggle`), receive segment response
   (`0x00 | toggle | (c << 0)`), accumulate data bytes until `c=1` (last segment).

Frame layout — upload segment request:
```
[0] = 0x60 | (toggle << 4)
[1..7] = 0x00
```

Frame layout — upload segment response:
```
[0] bit 4: toggle, bits 1-3: n (unused bytes), bit 0: c (last segment)
[1..7] = up to 7 data bytes
```

#### 4.2 — Segmented download (write > 4 bytes)

Flow:
1. Send initiate download request with `e=0`, `s=1`, size in bytes `[4..7]`.
2. Receive initiate download response.
3. Loop: chunk data into 7-byte segments, send download segment request, await ACK,
   flip toggle bit, until all bytes sent (set `c=1` on last segment).

Frame layout — initiate download request (non-expedited):
```
[0] = 0x21          // e=0, s=1
[1] = index low
[2] = index high
[3] = subIndex
[4..7] = size (LE)
```

Download segment request:
```
[0] = 0x00 | (toggle << 4) | (n << 1) | c
      n = 7 - bytes_in_this_segment
[1..7] = data bytes (zero-padded if last segment)
```

#### 4.3 — Auto-dispatch in `sdoRead` / `sdoWrite`

Modify the `_transact` core private method to detect `e` bit in the response and
delegate to the segmented path transparently. The public `sdoRead`/`sdoWrite` API
does **not** change.

#### 4.4 — Additional typed helpers

```dart
Future<Uint8List> sdoReadRaw(int nodeId, int index, int subIndex); // alias for sdoRead
Future<void> sdoWriteRaw(int nodeId, int index, int subIndex, Uint8List data);
Future<double> sdoReadF64(int nodeId, int index, int subIndex);
Future<void>   sdoWriteF64(int nodeId, int index, int subIndex, double value);
```

#### 4.5 — Write unit tests for segmented transfers

**File:** `test/sdo_segmented_test.dart`

- Segmented upload: mock returns a multi-segment response sequence; verify assembled
  `Uint8List` matches expected bytes.
- String read: `sdoReadString` returns `"Hello"` from a 5-byte segmented upload.
- Segmented download: mock verifies correct toggle sequence and correct chunk sizes.
- Toggle bit mismatch: throw `CanOpenException` with descriptive message.

### Commands
```bash
flutter test test/sdo_test.dart test/sdo_segmented_test.dart
```

### Acceptance Criteria
- [ ] Strings longer than 4 bytes are read correctly via segmented upload.
- [ ] Data larger than 4 bytes is written correctly via segmented download.
- [ ] Toggle bit is correctly alternated each segment.
- [ ] Toggle mismatch throws an exception.

---

## Phase 5 — PDO Manager

### Goals
Implement PDO transmit (send a PDO frame) and PDO receive (dispatch incoming frames
to registered callbacks).

### Tasks

#### 5.1 — Implement `PdoManager`

**File:** `lib/src/canopen/pdo.dart`

Internal state:
```dart
final Map<int, List<void Function(Uint8List)>> _callbacks = {};
late StreamSubscription<CanMessage> _rxSub;
```

Initialisation:
- Subscribe to `adapter.rxFrames`.
- For each frame, look up `_callbacks[cobId]` and invoke all registered functions.

**Public API:**
```dart
Future<void> sendPdo(int cobId, Uint8List data);
void registerPdoCallback(int cobId, void Function(Uint8List data) cb);
void unregisterAllCallbacks(int cobId);
void dispose();
```

Design notes:
- Support multiple callbacks per COB-ID (list, not single function).
- `sendPdo` validates data length ≤ 8 bytes; throws `CanOpenException` otherwise.

#### 5.2 — Write unit tests

**File:** `test/pdo_test.dart`

- `sendPdo(0x185, data)` delivers a frame with the correct COB-ID and data.
- Incoming frame on registered COB-ID fires all registered callbacks.
- Incoming frame on unregistered COB-ID is silently ignored.
- `unregisterAllCallbacks` prevents further callback invocations.
- Data > 8 bytes throws `CanOpenException`.

#### 5.3 — Export from barrel

```dart
export 'src/canopen/pdo.dart';
```

### Commands
```bash
flutter test test/pdo_test.dart
```

### Acceptance Criteria
- [ ] All PDO unit tests pass.
- [ ] Multiple callbacks per COB-ID all fire.
- [ ] Oversized PDO data rejected with a typed exception.

---

## Phase 6 — SYNC Manager & EMCY Manager

### Goals
Implement SYNC message production/consumption and Emergency message reception with
per-node history.

### Tasks

#### 6.1 — Implement `SyncManager`

**File:** `lib/src/canopen/sync.dart`

Internal state:
```dart
bool _counterEnabled = false;
int _counter = 0;                            // wraps 1..240
List<void Function(int?)> _rxCallbacks = [];
late StreamSubscription<CanMessage> _rxSub;
```

- `sendSync()`:
  - If `_counterEnabled`: increment `_counter` (1–240 wrap), send 1-byte frame.
  - Else: send 0-byte frame.
  - COB-ID = `0x080`.
- Rx: filter `rxFrames` for `cobId == 0x080`, parse optional counter byte, fire callbacks.

**Public API:**
```dart
Future<void> sendSync();
void setSyncCounterEnabled(bool enabled);
void resetCounter();
void registerSyncCallback(void Function(int? counter) cb);
void unregisterSyncCallback(void Function(int? counter) cb);
void dispose();
```

#### 6.2 — SYNC unit tests

**File:** `test/sync_test.dart`

- Without counter: `sendSync()` sends 0-byte frame on COB-ID `0x080`.
- With counter enabled: first call sends `[0x01]`, second sends `[0x02]`, ..., after 240
  wraps to `[0x01]`.
- Incoming SYNC frame fires all registered callbacks with correct counter value.

#### 6.3 — Implement `EmcyManager`

**File:** `lib/src/canopen/emcy.dart`

Model class:
```dart
class EmcyMessage {
  final int nodeId;
  final int errorCode;          // 2 bytes LE
  final int errorRegister;      // 1 byte
  final Uint8List mfrSpecificData;  // 5 bytes
  final DateTime timestamp;
  String get errorCodeDescription => _describeErrorCode(errorCode);
}
```

Internal state:
```dart
final Map<int, List<EmcyMessage>> _history = {};   // ring buffer per node
final Map<int, void Function(EmcyMessage)> _handlers = {};
late StreamSubscription<CanMessage> _rxSub;
static const int _maxHistory = 50;
```

Rx: filter `rxFrames` for `cobId >= 0x081 && cobId <= 0x0FF`:
- `nodeId = cobId - 0x080`.
- Parse 8-byte payload.
- Add to per-node ring buffer (drop oldest if > `_maxHistory`).
- Fire registered handler if present.

Error code descriptions: implement a `_describeErrorCode(int code)` function covering
the standard CiA 301 error code groups (0x1000–0x9FFF range descriptions).

**Public API:**
```dart
void registerEmcyHandler(int nodeId, void Function(EmcyMessage) cb);
void unregisterEmcyHandler(int nodeId);
List<EmcyMessage> getRecentEmcy(int nodeId, {int count = 10});
void clearHistory(int nodeId);
void dispose();
```

#### 6.4 — EMCY unit tests

**File:** `test/emcy_test.dart`

- Incoming EMCY frame parsed into `EmcyMessage` with correct fields.
- Registered handler fires on incoming frame.
- `getRecentEmcy` returns last N items (ring buffer overflow test).
- `errorCodeDescription` returns non-empty string for known codes.

### Commands
```bash
flutter test test/sync_test.dart test/emcy_test.dart
```

### Acceptance Criteria
- [ ] SYNC counter wraps correctly at 240.
- [ ] EMCY ring buffer does not exceed `_maxHistory` entries.
- [ ] All SYNC and EMCY unit tests pass.

---

## Phase 7 — LSS Client (Switch & Inquire Services)

### Goals
Implement the LSS protocol switch-state and inquire services (read-only commissioning).
These are the most commonly used LSS operations.

### Tasks

#### 7.1 — LSS frame constants

**File:** `lib/src/canopen/lss.dart` (constants section)

| Constant | Value |
|---|---|
| `lssCsSwitchGlobal` | 0x04 |
| `lssCsSwitchSelectiveVendor` | 0x40 |
| `lssCsSwitchSelectiveProduct` | 0x41 |
| `lssCsSwitchSelectiveRevision` | 0x42 |
| `lssCsSwitchSelectiveSerial` | 0x43 |
| `lssCsSwitchSelectiveResponse` | 0x44 |
| `lssCsInquireVendorId` | 0x5A |
| `lssCsInquireProductCode` | 0x5B |
| `lssCsInquireRevisionNumber` | 0x5C |
| `lssCsInquireSerialNumber` | 0x5D |
| `lssCsIdentifySlave` | 0x4F |
| `lssCsIdentifyNonConfigured` | 0x50 |

All LSS frames are exactly 8 bytes; unused bytes are 0x00.

#### 7.2 — `LssAddress` model

```dart
class LssAddress {
  final int vendorId;
  final int productCode;
  final int revisionNumber;
  final int serialNumber;
}
```

#### 7.3 — Implement `LssClient` (switch & inquire)

**File:** `lib/src/canopen/lss.dart`

Pending command support:
```dart
Completer<Uint8List>? _pending;
StreamSubscription<CanMessage>? _rxSub;
final Lock _lock = Lock();
```

`_transact(Uint8List txFrame, {Duration timeout})`:
1. Subscribe to `rxFrames` for `cobId == 0x7E4`.
2. Send frame on COB-ID `0x7E5`.
3. Await `Completer` with timeout.
4. Cancel subscription.

For multi-response inquiries (`lssInquireVendorIds` etc.):
- Collect all responses until `timeout` expires (use a `StreamController` + `Timer`).

**Public API (Phase 7):**
```dart
Future<void> lssSwitchStateGlobal(LssMode mode,
    {Duration timeout = const Duration(milliseconds: 100)});

Future<void> lssSwitchStateSelective(LssAddress address,
    {Duration timeout = const Duration(seconds: 1)});

Future<int> lssInquireVendorId(
    {Duration timeout = const Duration(seconds: 1)});
Future<int> lssInquireProductCode(
    {Duration timeout = const Duration(seconds: 1)});
Future<int> lssInquireRevisionNumber(
    {Duration timeout = const Duration(seconds: 1)});
Future<int> lssInquireSerialNumber(
    {Duration timeout = const Duration(seconds: 1)});

// Multi-response variants (collect all replies until timeout)
Future<List<int>> lssInquireVendorIds(
    {Duration timeout = const Duration(seconds: 2)});
Future<List<int>> lssInquireProductCodes(
    {Duration timeout = const Duration(seconds: 2)});
Future<List<int>> lssInquireRevisionNumbers(
    {Duration timeout = const Duration(seconds: 2)});
Future<List<int>> lssInquireSerialNumbers(
    {Duration timeout = const Duration(seconds: 2)});
```

#### 7.4 — Write unit tests

**File:** `test/lss_test.dart` (Part A)

- `lssSwitchStateGlobal(LssMode.configuration)` sends frame `[0x04, 0x01, 0, 0, 0, 0, 0, 0]`.
- `lssSwitchStateSelective` sends 4 consecutive frames with correct vendor/product/revision/serial.
- `lssInquireVendorId` sends correct inquiry frame and decodes 4-byte LE response.
- Multi-response: mock returns 2 responses; `lssInquireSerialNumbers` returns list of 2.
- Timeout with no response throws `CanOpenTimeoutException`.

### Commands
```bash
flutter test test/lss_test.dart
```

### Acceptance Criteria
- [ ] Switch global and selective frames have correct byte layout.
- [ ] Single and multi-response inquiries work correctly.
- [ ] Timeout path throws `CanOpenTimeoutException`.

---

## Phase 8 — LSS Client (Configure, Store & Fastscan)

### Goals
Complete the LSS implementation with node-ID configuration, bit-timing configuration,
store-to-NVM, and Fastscan discovery.

### Tasks

#### 8.1 — Additional LSS constants

| Constant | Value |
|---|---|
| `lssCsConfigureNodeId` | 0x11 |
| `lssCsConfigureNodeIdResponse` | 0x11 |
| `lssCsConfigureBitTiming` | 0x13 |
| `lssCsConfigureBitTimingResponse` | 0x13 |
| `lssCsActivateBitTiming` | 0x15 |
| `lssCsStoreConfiguration` | 0x17 |
| `lssCsStoreConfigurationResponse` | 0x17 |
| `lssCsFastscan` | 0x51 |
| `lssCsFastscanResponse` | 0x4F |

#### 8.2 — `LssError` enum

```dart
enum LssError {
  success(0),
  nodeIdOutOfRange(1),
  specificError(0xFF);
  final int code;
  String get description { … }
}
```

#### 8.3 — Implement configure / store / fastscan

**Public API (Phase 8 additions):**
```dart
Future<LssError> lssConfigureNodeId(int nodeId,
    {Duration timeout = const Duration(seconds: 1)});

Future<LssError> lssConfigureBitTiming(int tableSelector, int tableIndex,
    {Duration timeout = const Duration(seconds: 1)});

Future<void> lssActivateBitTiming(int switchDelayMs);

Future<LssError> lssStoreConfiguration(
    {Duration timeout = const Duration(seconds: 1)});

/// Fastscan — discover all unconfigured nodes on the network.
/// Returns list of [LssAddress] for each discovered device.
Future<List<LssAddress>> lssFastscan(
    {Duration timeout = const Duration(seconds: 5)});
```

Fastscan algorithm (simplified binary search per CiA 305 §12):
1. Send `IdentifyNonConfigured` broadcast; if no response, return empty list.
2. For each of the 4 identity fields (vendor, product, revision, serial):
   - Binary-search for matching value using `Fastscan` service.
3. Record found `LssAddress`, store node-ID, repeat until no more respond.

#### 8.4 — Write unit tests (Phase 8)

**File:** `test/lss_test.dart` (Part B, append)

- `lssConfigureNodeId(10)` sends correct frame and returns `LssError.success` on ACK 0x00.
- `lssConfigureNodeId(128)` returns `LssError.nodeIdOutOfRange` on error response.
- `lssStoreConfiguration` sends correct frame and returns `LssError.success`.
- Fastscan with mocked single-device response returns correct `LssAddress`.

### Commands
```bash
flutter test test/lss_test.dart
dart analyze
```

### Acceptance Criteria
- [ ] Configure node-ID and store configuration flows pass unit tests.
- [ ] `LssError` correctly mapped from response byte.
- [ ] Fastscan returns the expected `LssAddress` from mock responses.

---

## Phase 9 — `CanOpenSimple` Facade & Dartdoc

### Goals
Compose all managers into the single `CanOpenSimple` public entry point, complete the
barrel export, and add `///` dartdoc to every public symbol.

### Tasks

#### 9.1 — Implement `CanOpenSimple`

**File:** `lib/src/canopen_simple.dart`

```dart
class CanOpenSimple {
  CanOpenSimple({ICanAdapter? adapter})
      : _adapter = adapter ?? CanUsbAdapter();

  final ICanAdapter _adapter;
  NmtManager?  _nmt;
  SdoClient?   _sdo;
  PdoManager?  _pdo;
  SyncManager? _sync;
  EmcyManager? _emcy;
  LssClient?   _lss;
  bool _connected = false;

  Future<void> connect(String port, BusSpeed speed) async {
    await _adapter.connect(port, speed);
    _nmt  = NmtManager(_adapter);
    _sdo  = SdoClient(_adapter);
    _pdo  = PdoManager(_adapter);
    _sync = SyncManager(_adapter);
    _emcy = EmcyManager(_adapter);
    _lss  = LssClient(_adapter);
    _connected = true;
  }

  Future<void> disconnect() async {
    _disposeManagers();
    await _adapter.disconnect();
    _connected = false;
  }

  void dispose() {
    _disposeManagers();
    _adapter.dispose();
  }

  // ── SDO ──────────────────────────────────────────────────────────────
  Future<Uint8List> sdoRead(int nodeId, int index, int subIndex, …) { … }
  Future<void>      sdoWrite(int nodeId, int index, int subIndex, …) { … }
  Future<int>    sdoReadU8(int nodeId, int index, int subIndex) { … }
  Future<int>    sdoReadU16(int nodeId, int index, int subIndex) { … }
  Future<int>    sdoReadU32(int nodeId, int index, int subIndex) { … }
  Future<double> sdoReadF32(int nodeId, int index, int subIndex) { … }
  Future<String> sdoReadString(int nodeId, int index, int subIndex) { … }
  Future<void>   sdoWriteU8(…) { … }
  Future<void>   sdoWriteU16(…) { … }
  Future<void>   sdoWriteU32(…) { … }

  // ── NMT ──────────────────────────────────────────────────────────────
  Future<void> nmtStart(int nodeId) { … }
  Future<void> nmtStop(int nodeId) { … }
  Future<void> nmtEnterPreOperational(int nodeId) { … }
  Future<void> nmtResetNode(int nodeId) { … }
  Future<void> nmtResetCommunication(int nodeId) { … }
  NmtState getNodeState(int nodeId) { … }
  void registerHeartbeatCallback(int nodeId, void Function(int, NmtState) cb) { … }

  // ── PDO ──────────────────────────────────────────────────────────────
  Future<void> sendPdo(int cobId, Uint8List data) { … }
  void registerPdoCallback(int cobId, void Function(Uint8List) cb) { … }
  void unregisterAllPdoCallbacks(int cobId) { … }

  // ── SYNC ─────────────────────────────────────────────────────────────
  Future<void> sendSync() { … }
  void setSyncCounterEnabled(bool enabled) { … }
  void registerSyncCallback(void Function(int?) cb) { … }

  // ── EMCY ─────────────────────────────────────────────────────────────
  void registerEmcyHandler(int nodeId, void Function(EmcyMessage) cb) { … }
  List<EmcyMessage> getRecentEmcy(int nodeId, {int count = 10}) { … }

  // ── LSS ──────────────────────────────────────────────────────────────
  Future<void> lssSwitchStateGlobal(LssMode mode) { … }
  Future<void> lssSwitchStateSelective(LssAddress address) { … }
  Future<int>  lssInquireVendorId() { … }
  Future<int>  lssInquireSerialNumber() { … }
  Future<LssError> lssConfigureNodeId(int nodeId) { … }
  Future<LssError> lssStoreConfiguration() { … }
  Future<List<LssAddress>> lssFastscan() { … }
}
```

Internal guard helper (use in every proxy method):
```dart
T _requireConnected<T>(T Function() fn) {
  if (!_connected) throw StateError('Call connect() first');
  return fn();
}
```

#### 9.2 — Dartdoc

Add `///` doc-comments to every public:
- class, enum, typedef
- method (include `@param`, returns description, `@throws`)
- constant

Example pattern:
```dart
/// Reads an object dictionary entry from a remote node using SDO upload.
///
/// Handles both expedited (≤ 4 bytes) and segmented (> 4 bytes) transfers
/// transparently.
///
/// [nodeId] — CANopen node ID (1–127).
/// [index]  — Object dictionary index (e.g. 0x1000).
/// [subIndex] — Sub-index (e.g. 0x00).
/// [timeout] — Maximum wait time per segment (default 1 s).
///
/// Throws [SdoAbortException] if the remote node aborts the transfer.
/// Throws [CanOpenTimeoutException] if no response is received in time.
Future<Uint8List> sdoRead(…) { … }
```

#### 9.3 — Final barrel export

Ensure `lib/canopen_client.dart` exports all modules:
```dart
export 'src/canopen_simple.dart';
export 'src/canopen/message.dart';
export 'src/canopen/types.dart';
export 'src/canopen/nmt.dart';
export 'src/canopen/emcy.dart';
export 'src/canopen/lss.dart';
export 'src/errors.dart';
export 'src/hardware/i_can_adapter.dart';
export 'src/hardware/can_usb_adapter.dart';
// Internal implementation files (sdo, pdo, sync) — do NOT export directly.
```

#### 9.4 — Integration test for `CanOpenSimple`

**File:** `test/canopen_simple_test.dart`

- `connect()` initialises all managers.
- Calling any method before `connect()` throws `StateError`.
- `disconnect()` disposes all managers cleanly.

### Commands
```bash
flutter test
dart doc --validate-links .
dart analyze
dart format --set-exit-if-changed .
```

### Acceptance Criteria
- [ ] `flutter test` — all tests pass (target ≥ 80% line coverage).
- [ ] `dart doc` generates without broken-link warnings.
- [ ] `dart analyze` — zero issues.
- [ ] `dart format` — no changes needed.

---

## Phase 10 — Example App, README, CHANGELOG & Publishing

### Goals
Ship a working example, complete the package metadata, verify pub.dev scoring, and publish.

### Tasks

#### 10.1 — Example application

**File:** `example/canopen_client_example.dart`

```dart
import 'package:canopen_client/canopen_client.dart';

Future<void> main() async {
  final canopen = CanOpenSimple();

  // List available ports
  final ports = await canopen.listPorts();
  print('Available ports: $ports');

  // Connect at 1 Mbps
  await canopen.connect(ports.first, BusSpeed.baud1M);

  // Read device type from node 5
  final deviceType = await canopen.sdoReadU32(5, 0x1000, 0);
  print('Device type: 0x${deviceType.toRadixString(16).padLeft(8, '0')}');

  // Set heartbeat producer time to 1000 ms
  await canopen.sdoWriteU16(5, 0x1017, 0, 1000);

  // Start node in operational mode
  await canopen.nmtStart(5);

  // Register PDO callback
  canopen.registerPdoCallback(0x185, (data) {
    print('PDO 0x185: ${data.map((b) => b.toRadixString(16)).join(' ')}');
  });

  // Register emergency handler
  canopen.registerEmcyHandler(5, (emcy) {
    print('EMCY from node ${emcy.nodeId}: ${emcy.errorCodeDescription}');
  });

  // Send SYNC
  canopen.setSyncCounterEnabled(true);
  await canopen.sendSync();

  // LSS: read serial number
  await canopen.lssSwitchStateGlobal(LssMode.configuration);
  final serial = await canopen.lssInquireSerialNumber();
  print('Serial: 0x${serial.toRadixString(16)}');
  await canopen.lssSwitchStateGlobal(LssMode.operation);

  await canopen.disconnect();
  canopen.dispose();
}
```

#### 10.2 — README.md

Structure:
1. Badges (pub.dev version, license, platforms)
2. Features list (SDO/NMT/PDO/SYNC/EMCY/LSS bullet points)
3. Getting started (pubspec snippet + `flutter pub get`)
4. Usage — copy key snippets from the example above, one per protocol
5. API overview table (mirrors `MIGRATION_PLAN.md §9`)
6. Hardware requirements (`can_usb` compatible adapter)
7. Supported platforms
8. Contributing
9. License

#### 10.3 — CHANGELOG.md

```markdown
## 0.1.0

- Initial release.
- SDO client: expedited and segmented transfers, typed helpers.
- NMT: all commands, heartbeat consumer.
- PDO: TX/RX with multiple callbacks per COB-ID.
- SYNC: with optional counter (1–240).
- EMCY: per-node handler and history ring buffer.
- LSS: all 14 CiA 305 services including Fastscan.
- Hardware backend: `can_usb` (Windows, Linux, macOS, Android).
```

#### 10.4 — LICENSE

Use MIT. Copy standard MIT text, replacing `<year>` and `<author>`.

#### 10.5 — Final quality gates

```bash
# Static analysis
dart analyze

# Formatting
dart format --set-exit-if-changed .

# Tests + coverage
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html   # requires lcov

# Documentation
dart doc .

# pub.dev dry run (checks all metadata requirements)
flutter pub publish --dry-run
```

Review the `--dry-run` output and fix any warnings before the next step.

#### 10.6 — Publish

```bash
flutter pub publish
```

Follow the OAuth browser flow on first publish. After publishing, verify the package
appears on pub.dev and check the automated scoring (aim for ≥ 120/140 points).

### Acceptance Criteria
- [ ] Example compiles and runs without errors (hardware optional).
- [ ] `flutter pub publish --dry-run` exits with zero errors.
- [ ] Package appears on pub.dev with correct metadata.
- [ ] pub.dev score ≥ 120/140.
- [ ] All 6 protocol sections shown in README with code samples.

---

## Summary Table

| Phase | Key Deliverable | Primary Files | Status |
|---|---|---|---|
| 1 | Scaffold, HAL, models | `pubspec.yaml`, `i_can_adapter.dart`, `can_usb_adapter.dart`, `message.dart`, `types.dart`, `errors.dart`, `utils.dart` | ⬜ |
| 2 | NMT Manager | `nmt.dart`, `test/nmt_test.dart` | ⬜ |
| 3 | SDO expedited | `sdo.dart`, `test/sdo_test.dart` | ⬜ |
| 4 | SDO segmented | `sdo.dart` (extended), `test/sdo_segmented_test.dart` | ⬜ |
| 5 | PDO Manager | `pdo.dart`, `test/pdo_test.dart` | ⬜ |
| 6 | SYNC + EMCY | `sync.dart`, `emcy.dart`, `test/sync_test.dart`, `test/emcy_test.dart` | ⬜ |
| 7 | LSS switch/inquire | `lss.dart` (partial), `test/lss_test.dart` | ⬜ |
| 8 | LSS configure/fastscan | `lss.dart` (complete), `test/lss_test.dart` (extended) | ⬜ |
| 9 | Facade + dartdoc | `canopen_simple.dart`, `canopen_client.dart`, all dartdoc | ⬜ |
| 10 | Example + publish | `example/`, `README.md`, `CHANGELOG.md`, `LICENSE` | ⬜ |
