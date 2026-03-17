/// Concrete [ICanAdapter] implementation backed by the `can_usb` package.
library;

import 'dart:async';

import 'package:can_usb/can_usb.dart';
import 'package:canopen_client/src/canopen/message.dart';
import 'package:canopen_client/src/canopen/types.dart';
import 'package:canopen_client/src/errors.dart';
import 'package:canopen_client/src/hardware/i_can_adapter.dart';

/// A [ICanAdapter] that communicates via the `can_usb` package.
///
/// Uses [CanusbDevice] under the hood, which drives a USB-CANFD adapter over
/// a serial (USB-CDC / UART) connection using the binary frame protocol
/// described in the adapter firmware's FRAME_SPECIFICATION.
///
/// ## Dependency injection / testing
/// Supply a custom [ISerialTransport] to run without real hardware:
/// ```dart
/// final mock = MyMockTransport();
/// final adapter = CanUsbAdapter(transport: mock);
/// ```
class CanUsbAdapter implements ICanAdapter {
  /// Creates a [CanUsbAdapter].
  ///
  /// An optional [transport] may be supplied for unit testing.  When omitted
  /// [CanusbDevice] automatically selects the correct transport for the
  /// current platform ([AndroidSerialTransport] on Android,
  /// [SerialPortTransport] elsewhere).
  CanUsbAdapter({ISerialTransport? transport})
      : _device = CanusbDevice(transport: transport);

  final CanusbDevice _device;

  // Broadcast stream controller wrapping device.rxFrames.
  StreamController<CanMessage>? _controller;
  StreamSubscription<CanFrame>? _deviceSub;

  @override
  Stream<CanMessage> get rxFrames {
    _controller ??= _createController();
    return _controller!.stream;
  }

  StreamController<CanMessage> _createController() {
    final ctrl = StreamController<CanMessage>.broadcast();
    _deviceSub = _device.rxFrames.listen(
      (frame) => ctrl.add(_frameToMessage(frame)),
      onError: ctrl.addError,
    );
    return ctrl;
  }

  @override
  bool get isConnected => _device.isConnected;

  @override
  Future<List<String>> listPorts() async {
    try {
      final ports = await _device.listAvailablePorts();
      return ports.map((p) => p.name).toList();
    } on Exception catch (e) {
      throw HardwareException('Failed to list ports: $e');
    }
  }

  @override
  Future<void> connect(String port, BusSpeed speed) async {
    // Ensure the rx stream controller is created before we open the port so
    // that no frames are dropped between connect and the first listen.
    _controller ??= _createController();

    try {
      await _device.connect(port);
      await _device.canStart();
    } on CanConnectionException catch (e) {
      throw HardwareException('Failed to connect to $port: $e');
    } on Exception catch (e) {
      throw HardwareException('Unexpected error connecting to $port: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _device.canStop();
    } on Exception {
      // Best-effort: device may already be unreachable (e.g. physically
      // removed). Always proceed to disconnect regardless.
    }
    try {
      await _device.disconnect();
    } on Exception catch (e) {
      throw HardwareException('Failed to disconnect: $e');
    }
  }

  @override
  Future<void> send(CanMessage message) async {
    final frame = CanFrame(
      frameType: const CanFrameType.classic(),
      messageId: message.cobId,
      dlc: message.data.length,
      data: message.data,
    );
    try {
      await _device.sendFrame(frame);
    } on Exception catch (e) {
      throw HardwareException('Failed to send frame: $e');
    }
  }

  @override
  void dispose() {
    _deviceSub?.cancel();
    _deviceSub = null;
    _controller?.close();
    _controller = null;
    _device.dispose();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  static CanMessage _frameToMessage(CanFrame frame) => CanMessage(
        cobId: frame.messageId,
        data: frame.data,
      );
}
