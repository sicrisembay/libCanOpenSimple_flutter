import 'dart:typed_data';

import 'package:canopen_client/canopen_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CanMessage', () {
    test('stores cobId, data and isRtr correctly', () {
      final data = Uint8List.fromList([0x01, 0x02, 0x03]);
      final msg = CanMessage(cobId: 0x185, data: data, isRtr: false);
      expect(msg.cobId, 0x185);
      expect(msg.data, [0x01, 0x02, 0x03]);
      expect(msg.isRtr, isFalse);
    });

    test('isRtr defaults to false', () {
      final msg = CanMessage(cobId: 0x000, data: Uint8List(0));
      expect(msg.isRtr, isFalse);
    });

    test('equality — same content compares equal', () {
      final a =
          CanMessage(cobId: 0x200, data: Uint8List.fromList([0xAA, 0xBB]));
      final b =
          CanMessage(cobId: 0x200, data: Uint8List.fromList([0xAA, 0xBB]));
      expect(a, equals(b));
    });

    test('equality — different cobId is not equal', () {
      final a = CanMessage(cobId: 0x100, data: Uint8List.fromList([0x01]));
      final b = CanMessage(cobId: 0x200, data: Uint8List.fromList([0x01]));
      expect(a, isNot(equals(b)));
    });

    test('equality — different data is not equal', () {
      final a = CanMessage(cobId: 0x100, data: Uint8List.fromList([0x01]));
      final b = CanMessage(cobId: 0x100, data: Uint8List.fromList([0x02]));
      expect(a, isNot(equals(b)));
    });

    test('toString contains hex cobId', () {
      final msg = CanMessage(cobId: 0x605, data: Uint8List.fromList([0x40]));
      expect(msg.toString(), contains('605'));
    });
  });

  group('CobId helpers', () {
    test('sdoTx returns sdoTxBase + nodeId', () {
      expect(CobId.sdoTx(5), 0x580 + 5);
      expect(CobId.sdoTx(1), 0x581);
      expect(CobId.sdoTx(127), 0x580 + 127);
    });

    test('sdoRx returns sdoRxBase + nodeId', () {
      expect(CobId.sdoRx(5), 0x600 + 5);
    });

    test('heartbeat returns heartbeatBase + nodeId', () {
      expect(CobId.heartbeat(5), 0x700 + 5);
    });

    test('emerg returns emergBase + nodeId', () {
      expect(CobId.emerg(5), 0x080 + 5);
    });

    test('tpdo1 returns tpdo1Base + nodeId', () {
      expect(CobId.tpdo1(1), 0x180 + 1);
    });

    test('rpdo1 returns rpdo1Base + nodeId', () {
      expect(CobId.rpdo1(1), 0x200 + 1);
    });

    test('base constants have expected values', () {
      expect(CobId.nmtBase, 0x000);
      expect(CobId.syncBase, 0x080);
      expect(CobId.sdoTxBase, 0x580);
      expect(CobId.sdoRxBase, 0x600);
      expect(CobId.heartbeatBase, 0x700);
      expect(CobId.lss, 0x7E4);
      expect(CobId.lssMaster, 0x7E5);
    });
  });
}
