/// Abstract CAN adapter interface for hardware-agnostic CANopen communication.
library;

import 'package:canopen_client/src/canopen/message.dart';
import 'package:canopen_client/src/canopen/types.dart';
import 'package:canopen_client/src/errors.dart';

/// Abstract interface for a CAN bus adapter.
///
/// All CANopen protocol logic uses [ICanAdapter] exclusively, making it
/// possible to swap hardware backends or inject mock adapters in tests.
///
/// ## Typical usage
/// ```dart
/// final adapter = CanUsbAdapter();
/// final ports = await adapter.listPorts();
/// await adapter.connect(ports.first, BusSpeed.baud1M);
///
/// adapter.rxFrames.listen((msg) => print('RX: $msg'));
/// await adapter.send(CanMessage(cobId: 0x000, data: Uint8List.fromList([0x01, 0x05])));
///
/// await adapter.disconnect();
/// adapter.dispose();
/// ```
abstract class ICanAdapter {
  /// Broadcast stream of CAN frames received from the bus.
  ///
  /// Listeners are added before calling [connect] so that no early frames
  /// are missed. The stream must be a broadcast stream.
  Stream<CanMessage> get rxFrames;

  /// Broadcast stream of CAN frames successfully transmitted by [send].
  ///
  /// The default implementation returns an empty stream. Concrete adapters
  /// that want to expose outgoing traffic (e.g. for monitoring) should
  /// override this property.
  Stream<CanMessage> get txFrames => const Stream.empty();

  /// Returns the names of all available serial ports/CAN adapters.
  ///
  /// Throws [HardwareException] if the port enumeration fails.
  Future<List<String>> listPorts();

  /// Opens the serial port identified by [port] and starts the CAN peripheral
  /// at the specified [speed].
  ///
  /// [port]  — Port name as returned by [listPorts] (e.g. `'COM3'`, `'/dev/ttyUSB0'`).
  /// [speed] — CAN bus bit rate.
  ///
  /// Throws [HardwareException] if the port cannot be opened.
  Future<void> connect(String port, BusSpeed speed);

  /// Stops the CAN peripheral and closes the serial port.
  ///
  /// Throws [HardwareException] if the disconnection fails.
  Future<void> disconnect();

  /// Returns `true` if the adapter is currently connected to the hardware.
  ///
  /// The default implementation always returns `true`; concrete adapters
  /// should override this to reflect real transport state.
  bool get isConnected => true;

  /// Transmits a single CAN [message] on the bus.
  ///
  /// Throws [HardwareException] if the adapter is not connected or the
  /// transmission fails.
  Future<void> send(CanMessage message);

  /// Releases all resources held by this adapter.
  ///
  /// Must be called when the adapter is no longer needed. After calling
  /// [dispose], no further method calls are valid.
  void dispose();
}
