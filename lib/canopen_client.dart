/// CANopen master/client library for Flutter.
///
/// Provides SDO, NMT, PDO, SYNC, EMCY and LSS (CiA 301, CiA 305) protocol
/// support over a USB-CANFD adapter using the `can_usb` package.
///
/// ## Quick start
/// ```dart
/// import 'package:canopen_client/canopen_client.dart';
///
/// final canopen = CanOpenSimple();
/// await canopen.connect('COM3', BusSpeed.baud1M);
/// final deviceType = await canopen.sdoReadU32(5, 0x1000, 0);
/// await canopen.nmtStart(5);
/// await canopen.disconnect();
/// canopen.dispose();
/// ```
library canopen_client;

// All-in-one facade
export 'src/canopen_simple.dart';

// Core models
export 'src/canopen/message.dart';
export 'src/canopen/types.dart';

// CANopen protocol modules
export 'src/canopen/nmt.dart';
export 'src/canopen/sdo.dart';
export 'src/canopen/pdo.dart';
export 'src/canopen/sync.dart';
export 'src/canopen/emcy.dart';
export 'src/canopen/lss.dart';

// Errors
export 'src/errors.dart';

// Hardware abstraction
export 'src/hardware/i_can_adapter.dart';
export 'src/hardware/can_usb_adapter.dart';
