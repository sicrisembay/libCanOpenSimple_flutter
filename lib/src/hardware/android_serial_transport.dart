/// [AndroidSerialTransport] — [ISerialTransport] for Android USB Host API.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:can_usb/can_usb.dart';
import 'package:usb_serial/usb_serial.dart';

/// [ISerialTransport] implementation for Android using the [usb_serial] package.
///
/// Unlike [SerialPortTransport] (backed by `flutter_libserialport`), this
/// transport uses the Android USB Host API via [UsbSerial] / [UsbPort], which
/// does NOT scan `/sys/class/tty` and therefore works correctly inside the
/// SELinux sandbox of a normal Android application.
///
/// Physical USB removal is detected in two complementary ways:
/// - [UsbSerial.usbEventStream] fires [UsbEvent.ACTION_USB_DETACHED] immediately.
/// - The [UsbPort.inputStream] `onError` callback fires shortly after.
/// Both set [isConnected] to `false` so the caller's watchdog picks it up.
class AndroidSerialTransport implements ISerialTransport {
  // Broadcast stream controller — keeps the stream alive across connections.
  final _controller = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _inputSub;
  StreamSubscription<UsbEvent>? _usbEventSub;
  UsbPort? _port;

  @override
  bool get isConnected => _port != null;

  @override
  Stream<Uint8List> get dataStream => _controller.stream;

  // ── Port enumeration ────────────────────────────────────────────────────────

  @override
  Future<List<SerialPortInfo>> listAvailablePorts() async {
    final devices = await UsbSerial.listDevices();
    return devices.map((d) {
      final parts = <String>[];
      if (d.productName?.isNotEmpty == true) parts.add(d.productName!);
      if (d.vid != null && d.pid != null) {
        final vid = d.vid!.toRadixString(16).toUpperCase().padLeft(4, '0');
        final pid = d.pid!.toRadixString(16).toUpperCase().padLeft(4, '0');
        parts.add('(VID:$vid PID:$pid)');
      }
      return SerialPortInfo(
        name: d.deviceName,
        description: parts.isNotEmpty ? parts.join(' ') : null,
      );
    }).toList();
  }

  // ── Connection management ───────────────────────────────────────────────────

  @override
  Future<void> connect(String portName, {int baudRate = 115200}) async {
    if (_port != null) await disconnect();

    // Subscribe to USB system events before opening the port so that a
    // detach that races with connect() is still observed.
    _usbEventSub = UsbSerial.usbEventStream?.listen((event) {
      if (event.event == UsbEvent.ACTION_USB_DETACHED) {
        _inputSub?.cancel();
        _inputSub = null;
        _port = null;
        _usbEventSub?.cancel();
        _usbEventSub = null;
      }
    });

    // Re-list to get fresh device references.
    final devices = await UsbSerial.listDevices();
    final device = devices.firstWhere(
      (d) => d.deviceName == portName,
      orElse: () =>
          throw CanConnectionException('USB device not found: $portName. '
              'Ensure the device is still connected.'),
    );

    // create() requests Android USB permission automatically if needed.
    final port = await device.create();
    if (port == null) {
      throw CanConnectionException(
        'Could not open USB serial port: $portName. '
        'USB permission may have been denied or the device driver '
        '(CDC/ACM) is not supported.',
      );
    }

    final opened = await port.open();
    if (!opened) {
      throw CanConnectionException('Failed to open USB port: $portName');
    }

    await port.setPortParameters(
      baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );

    _port = port;
    _inputSub = port.inputStream?.listen(
      _controller.add,
      onError: (Object err) {
        _controller.addError(err);
        // A read error means the USB device was physically removed.
        // Null out _port so isConnected returns false immediately.
        _inputSub = null;
        _port = null;
        _usbEventSub?.cancel();
        _usbEventSub = null;
      },
    );
  }

  @override
  Future<void> disconnect() async {
    await _usbEventSub?.cancel();
    _usbEventSub = null;
    await _inputSub?.cancel();
    _inputSub = null;
    await _port?.close();
    _port = null;
  }

  @override
  Future<void> write(Uint8List data) async {
    final port = _port;
    if (port == null) throw CanConnectionException('Not connected');
    await port.write(data);
  }
}
