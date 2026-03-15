# libCANopenSimple Flutter Migration Plan

## 1. Overview & Goals

| Item | Detail |
|---|---|
| Package name (suggested) | `canopen_client` |
| Target SDK | Flutter ≥ 3.22 / Dart ≥ 3.5 |
| Hardware backend | `can_usb ^0.1.1` |
| Supported platforms | Windows, Linux, macOS, Android (wherever `can_usb` runs) |
| Publication target | pub.dev |

The Flutter package reimplements the same CANopen master/client logic from the C# original
([libCanopenSimple](https://github.com/sicrisembay/CANopen_FirmwareLoader/tree/main/libCanOpenSimple))
and the Rust port ([libCanOpenSimple_rs](https://github.com/sicrisembay/LibCANopen-client-rs)),
but in pure Dart. It is **not** a CANopen device — no OD server, no SDO server.
CAN I/O is fully delegated to `can_usb`.

---

## 2. Repository & Package Structure

```
canopen_client/
├── lib/
│   ├── canopen_client.dart          # Barrel export file
│   └── src/
│       ├── hardware/
│       │   ├── i_can_adapter.dart   # Abstract hardware interface
│       │   └── can_usb_adapter.dart # can_usb concrete implementation
│       ├── canopen/
│       │   ├── message.dart         # CanMessage model + COB-ID constants
│       │   ├── types.dart           # BusSpeed, NmtState, LssMode enums
│       │   ├── od.dart              # OD index/subindex helpers
│       │   ├── sdo.dart             # SDO client state machine
│       │   ├── nmt.dart             # NMT commands + heartbeat consumer
│       │   ├── pdo.dart             # PDO TX/RX + callback registry
│       │   ├── sync.dart            # SYNC producer + consumer
│       │   ├── emcy.dart            # Emergency message consumer
│       │   └── lss.dart             # LSS client (all 14 services)
│       ├── errors.dart              # CanOpenException hierarchy
│       └── utils.dart               # Byte helpers, cob-id encoder/decoder
├── test/
│   ├── sdo_test.dart
│   ├── nmt_test.dart
│   ├── pdo_test.dart
│   ├── sync_test.dart
│   ├── emcy_test.dart
│   └── lss_test.dart
├── example/
│   └── canopen_client_example.dart
├── pubspec.yaml
├── README.md
├── CHANGELOG.md
└── LICENSE                          # MIT
```

---

## 3. pubspec.yaml

```yaml
name: canopen_client
description: A CANopen master/client library for Flutter with SDO, NMT, PDO, SYNC, EMCY and LSS support.
version: 0.1.0
homepage: https://github.com/<your-org>/canopen_client

environment:
  sdk: '>=3.5.0 <4.0.0'
  flutter: '>=3.22.0'

dependencies:
  flutter:
    sdk: flutter
  can_usb: ^0.1.1
  synchronized: ^3.1.0   # Re-exported transitively from can_usb; good for SDO mutex

dev_dependencies:
  flutter_test:
    sdk: flutter
  mockito: ^5.4.0
  build_runner: ^2.4.0
  very_good_analysis: ^7.0.0  # strict linting for pub.dev score
```

---

## 4. Hardware Abstraction Layer

### 4.1 Abstract Interface — `i_can_adapter.dart`

Map the `ISerialTransport`-style design of `can_usb` behind your own thin interface so all
CANopen logic is hardware-agnostic and fully testable with mocks.

```dart
abstract class ICanAdapter {
  Stream<CanMessage> get rxFrames;                 // incoming messages
  Future<void> connect(String port, BusSpeed speed);
  Future<void> disconnect();
  Future<void> send(CanMessage message);
  Future<List<String>> listPorts();
  void dispose();
}
```

### 4.2 Concrete Implementation — `can_usb_adapter.dart`

- Wraps `CanusbDevice` from `can_usb`.
- `connect()` → `device.connect(port)` then `device.canStart()`.
- `disconnect()` → `device.canStop()` then `device.disconnect()`.
- `send()` → constructs `CanFrame(id: msg.cobId, frameType: CanFrameType.classic(), data: msg.data)`
  then calls `device.sendFrame()`.
- `rxFrames` → maps `device.rxFrames` stream from `CanFrame` to your `CanMessage` model.
- `listPorts()` → `device.listAvailablePorts()`.
- Bus speed: encode as integer kbps or pass as a parameter to `canStart()` (check if `can_usb`
  exposes baud-rate configuration).

---

## 5. Core Data Models

### 5.1 `CanMessage` (`message.dart`)

```dart
class CanMessage {
  final int cobId;          // 11-bit COB-ID
  final bool isRtr;
  final Uint8List data;     // 0–8 bytes (CAN Classic)
  const CanMessage({required this.cobId, required this.data, this.isRtr = false});
}
```

### 5.2 COB-ID Constants

```dart
abstract class CobId {
  static const int nmtBase       = 0x000;
  static const int syncBase      = 0x080;
  static const int emergBase     = 0x080; // 0x080 + nodeId
  static const int tpdo1Base     = 0x180;
  static const int rpdo1Base     = 0x200;
  // … TPDO2–4, RPDO2–4, SDO_RX, SDO_TX, NMT heartbeat …
  static const int sdoTxBase     = 0x580;
  static const int sdoRxBase     = 0x600;
  static const int heartbeatBase = 0x700;
  static const int lss           = 0x7E4; // LSS slave→master
  static const int lssMaster     = 0x7E5; // LSS master→slave
}
```

### 5.3 Enums (`types.dart`)

- `BusSpeed` (10k … 1M)
- `NmtState` (bootUp, stopped, operational, preOperational)
- `NmtCommand` (start, stop, enterPreOp, resetNode, resetComm)
- `LssMode` (operation, configuration)
- `SdoAbortCode`
- `EmcyErrorCode`

---

## 6. Module Implementations

### 6.1 SDO Client (`sdo.dart`)

**Expedited (≤ 4 bytes)**
- Send initiate-download / initiate-upload command frames.
- Await reply on `sdoTxBase + nodeId` with a `Completer` + timeout guard using `Future.timeout()`.

**Segmented (> 4 bytes)**
- State machine: `idle → initDone → segmenting → done`.
- Use a `StreamSubscription` on `rxFrames` filtered to the reply COB-ID, advancing the state on
  each segment ACK.

**Block transfers** — optional future phase.

**Public API:**
```dart
Future<Uint8List> sdoRead(int nodeId, int index, int subIndex,
    {Duration timeout = const Duration(seconds: 1)});

Future<void> sdoWrite(int nodeId, int index, int subIndex, Uint8List data,
    {Duration timeout = const Duration(seconds: 1)});

// Typed convenience wrappers
Future<int>    sdoReadU8(int nodeId, int index, int subIndex);
Future<int>    sdoReadU16(int nodeId, int index, int subIndex);
Future<int>    sdoReadU32(int nodeId, int index, int subIndex);
Future<double> sdoReadFloat32(int nodeId, int index, int subIndex);
Future<String> sdoReadString(int nodeId, int index, int subIndex);
Future<void>   sdoWriteU8(int nodeId, int index, int subIndex, int value);
// … etc.
```

**Concurrency guard**: wrap all SDO operations in a per-node `Mutex` (use `synchronized` package)
to prevent overlapping transactions.

---

### 6.2 NMT (`nmt.dart`)

- `sendNmtCommand(NmtCommand cmd, int nodeId)` → sends a 2-byte frame to COB-ID 0x000.
- **Heartbeat consumer**: subscribe to `rxFrames` where `cobId == 0x700 + nodeId`, parse the
  single-byte state byte, fire `void Function(int nodeId, NmtState state)` callbacks.
- Store last-known `Map<int, NmtState> _nodeStates`.

**Public API:**
```dart
Future<void> nmtStart(int nodeId);
Future<void> nmtStop(int nodeId);
Future<void> nmtEnterPreOperational(int nodeId);
Future<void> nmtResetNode(int nodeId);
Future<void> nmtResetCommunication(int nodeId);
NmtState? getNodeState(int nodeId);
void registerHeartbeatCallback(int nodeId, void Function(int, NmtState) cb);
void unregisterHeartbeatCallback(int nodeId);
```

---

### 6.3 PDO (`pdo.dart`)

- Maintain a `Map<int, List<void Function(Uint8List)>> _callbacks` keyed by COB-ID.
- The receive dispatcher reads from `rxFrames` and invokes all matching callbacks.

**Public API:**
```dart
Future<void> sendPdo(int cobId, Uint8List data);
void registerPdoCallback(int cobId, void Function(Uint8List data) cb);
void unregisterPdoCallback(int cobId);
```

---

### 6.4 SYNC (`sync.dart`)

- Sends 0-byte (no counter) or 1-byte (counter 1–240) frame to COB-ID 0x080.
- Auto-increments counter when enabled.
- Optional `registerSyncCallback(void Function(int? counter) cb)` for receiving SYNC.

**Public API:**
```dart
Future<void> sendSync();
void setSyncCounterEnabled(bool enabled);
void registerSyncCallback(void Function(int?) cb);
```

---

### 6.5 EMCY (`emcy.dart`)

- Filter `rxFrames` where `cobId == 0x080 + nodeId`.
- Parse 8-byte payload: `errorCode (2B) + errorRegister (1B) + mfrData (5B)`.
- Keep a ring buffer of last N emergencies per node.

**Public API:**
```dart
void registerEmcyHandler(int nodeId, void Function(EmcyMessage) cb);
List<EmcyMessage> getRecentEmcy(int nodeId, {int count = 10});
```

```dart
class EmcyMessage {
  final int nodeId;
  final int errorCode;
  final int errorRegister;
  final Uint8List mfrSpecificData;
  final DateTime timestamp;
  String get errorCodeDescription => EmcyErrorCode.describe(errorCode);
}
```

---

### 6.6 LSS (`lss.dart`)

Implement all 14 LSS services (CiA 305):

| Service | Command Specifier |
|---|---|
| Switch global (config/op) | 0x04 |
| Switch selective (4 frames: vendor/product/revision/serial) | 0x40–0x43 |
| Configure node-ID | 0x11 |
| Configure bit timing | 0x13 |
| Activate bit timing | 0x15 |
| Store configuration | 0x17 |
| Inquire vendor ID / product / revision / serial | 0x5A–0x5D |
| Identify slave | 0x4F |
| LSS identify non-configured | 0x4C |
| LSS Fastscan | 0x51 |

Use a `Completer` per pending command and a single `StreamSubscription` on COB-ID 0x7E4 for
responses.

**Public API:**
```dart
Future<void> lssSwitchStateGlobal(LssMode mode);
Future<void> lssSwitchStateSelective(LssAddress address, {Duration timeout});
Future<int>  lssInquireVendorId({Duration timeout});
Future<int>  lssInquireProductCode({Duration timeout});
Future<int>  lssInquireRevisionNumber({Duration timeout});
Future<int>  lssInquireSerialNumber({Duration timeout});
Future<List<int>> lssInquireVendorIds({Duration timeout});    // multi-response
Future<LssError>  lssConfigureNodeId(int nodeId, {Duration timeout});
Future<void> lssStoreConfiguration({Duration timeout});
```

---

## 7. Main Facade — `CanOpenSimple`

This is the single public-facing class consumers instantiate. It composes all modules.

```dart
class CanOpenSimple {
  CanOpenSimple({ICanAdapter? adapter})
      : _adapter = adapter ?? CanUsbAdapter();

  final ICanAdapter _adapter;
  late final SdoClient   _sdo;
  late final NmtManager  _nmt;
  late final PdoManager  _pdo;
  late final SyncManager _sync;
  late final EmcyManager _emcy;
  late final LssClient   _lss;

  Future<void> connect(String port, BusSpeed speed) async { … }
  Future<void> disconnect() async { … }

  // SDO proxies
  Future<Uint8List> sdoRead(int nodeId, int index, int subIndex);
  Future<void>      sdoWrite(int nodeId, int index, int subIndex, Uint8List data);
  // NMT proxies
  Future<void> nmtStart(int nodeId);
  // PDO proxies
  void registerPdoCallback(int cobId, void Function(Uint8List) cb);
  // SYNC proxies
  Future<void> sendSync();
  // EMCY proxies
  void registerEmcyHandler(int nodeId, void Function(EmcyMessage) cb);
  // LSS proxies
  Future<void> lssSwitchStateGlobal(LssMode mode);
  // … etc.

  void dispose() => _adapter.dispose();
}
```

---

## 8. Error Handling

```dart
class CanOpenException       implements Exception { final String message; … }
class SdoAbortException      extends CanOpenException { final int abortCode; … }
class CanOpenTimeoutException extends CanOpenException { … }
class LssException           extends CanOpenException { final LssError error; … }
class HardwareException      extends CanOpenException { … }
```

All async public methods return `Future<T>` and throw typed exceptions rather than returning null.

---

## 9. Testing Strategy

### 9.1 Unit Tests (no hardware required)

- Create `MockCanAdapter` implementing `ICanAdapter` using `mockito`.
- Inject it into `CanOpenSimple(adapter: mock)`.
- For each module, assert correct frame bytes are sent and simulate response frames by pushing to a
  `StreamController<CanMessage>`.

### 9.2 Integration / Hardware Tests

- Place in `test/hardware/` and gate with `--dart-define=RUN_HW_TESTS=true`.
- Connect a real USB-CANFD adapter running a CANopen device.

### 9.3 Coverage Target

Aim for ≥ 80% line coverage to achieve a good pub.dev score.

---

## 10. pub.dev Publication Checklist

| Requirement | Action |
|---|---|
| `pubspec.yaml` `description` 60–180 chars | Write concise package description |
| Valid `homepage` / `repository` | Point to GitHub |
| `CHANGELOG.md` with semantic versioning | Document every release |
| `LICENSE` | MIT (matches `can_usb`) |
| `README.md` | Quick-start, API overview, protocol examples |
| Dartdoc on all public APIs | `///` doc comments on every public symbol |
| Zero `dart analyze` warnings | Use `very_good_analysis` or `flutter_lints` |
| Format: `dart format .` | Run before every publish |
| Example app in `example/` | Mandatory for pub.dev score |
| Platform tags in `pubspec.yaml` | Declare `platforms: android: linux: macos: windows:` |
| Publish dry run | `flutter pub publish --dry-run` |

---

## 11. Migration Phase Plan

| Phase | Deliverable |
|---|---|
| 1 | Repo setup, `pubspec.yaml`, `i_can_adapter.dart`, `can_usb_adapter.dart`, `CanMessage` model |
| 2 | `NmtManager` + unit tests |
| 3 | `SdoClient` — expedited read/write + unit tests |
| 4 | `SdoClient` — segmented transfers + typed helpers |
| 5 | `PdoManager` + unit tests |
| 6 | `SyncManager` + `EmcyManager` + unit tests |
| 7 | `LssClient` — switch/inquire services |
| 8 | `LssClient` — configure/store/fastscan |
| 9 | `CanOpenSimple` facade, barrel export, dartdoc |
| 10 | Example app, README, CHANGELOG, pub.dev dry-run + publish |

---

## 12. Key Dart/Flutter-Specific Considerations

- **Streams over callbacks**: Use `StreamController<T>.broadcast()` instead of raw
  `void Function()` callbacks to allow multiple listeners and easy `listen()`/`cancel()` lifecycle.
- **Isolates**: CAN Rx processing is lightweight; Dart's async loop is sufficient. Only move to an
  `Isolate` if profiling shows jank.
- **`ByteData` / `Uint8List`**: Use Dart's `ByteData` for parsing multi-byte integers with correct
  endianness (`getUint32(0, Endian.little)`).
- **`synchronized` package**: Already a transitive dependency of `can_usb`; use `Lock` for
  per-node SDO serialisation.
- **No `dart:ffi`**: Everything goes through `can_usb`'s Dart API — no native bindings needed.
- **Null safety**: Full sound null safety from day one.
- **Semantic versioning**: Start at `0.1.0`; breaking API changes require a major bump before
  `1.0.0`.

---

## 13. References

- C# original: [libCanopenSimple](https://github.com/sicrisembay/CANopen_FirmwareLoader/tree/main/libCanOpenSimple)
- Rust port: [libCANopen-client-rs](https://github.com/sicrisembay/LibCANopen-client-rs)
- CAN adapter: [can_usb on pub.dev](https://pub.dev/packages/can_usb)
- CANopen specs: [CiA 301](https://www.can-cia.org/can-knowledge/canopen/canopen/) (application layer),
  [CiA 305](https://www.can-cia.org/can-knowledge/canopen/special-interest-groups/layer-setting-services-lss/) (LSS)
