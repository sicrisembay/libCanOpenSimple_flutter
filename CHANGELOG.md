## 0.1.0

- Initial release.
- `CanOpenSimple` all-in-one facade composing all six protocol managers.
- **SDO**: expedited and segmented upload/download; typed helpers for
  `u8`, `u16`, `u32`, `f32`, `f64`, and `String`.
- **NMT**: Start, Stop, Pre-Operational, Reset Node, Reset Communication;
  heartbeat consumer with per-node state callbacks.
- **PDO**: transmit and receive frames; multiple callbacks per COB-ID.
- **SYNC**: optional counter (1–240); incoming SYNC callbacks.
- **EMCY**: per-node handler registration; ring-buffer message history.
- **LSS** (CiA 305): global/selective switch, identity inquiry,
  node-ID and bit-timing configuration, NVM store, Fastscan discovery.
- Hardware backend: `can_usb ^0.1.1` (Windows, Linux, macOS, Android).
- Injectable `ICanAdapter` interface for unit testing.
