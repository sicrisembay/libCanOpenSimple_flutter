import 'package:canopen_client/canopen_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BusSpeed', () {
    test('kbps values are correct', () {
      expect(BusSpeed.baud10k.kbps, 10);
      expect(BusSpeed.baud20k.kbps, 20);
      expect(BusSpeed.baud50k.kbps, 50);
      expect(BusSpeed.baud100k.kbps, 100);
      expect(BusSpeed.baud125k.kbps, 125);
      expect(BusSpeed.baud250k.kbps, 250);
      expect(BusSpeed.baud500k.kbps, 500);
      expect(BusSpeed.baud800k.kbps, 800);
      expect(BusSpeed.baud1M.kbps, 1000);
    });
  });

  group('NmtState', () {
    test('fromByte parses known state bytes', () {
      expect(NmtStateExt.fromByte(0x00), NmtState.bootUp);
      expect(NmtStateExt.fromByte(0x04), NmtState.stopped);
      expect(NmtStateExt.fromByte(0x05), NmtState.operational);
      expect(NmtStateExt.fromByte(0x7F), NmtState.preOperational);
    });

    test('fromByte returns unknown for unrecognised byte', () {
      expect(NmtStateExt.fromByte(0x99), NmtState.unknown);
    });

    test('stateByte round-trips', () {
      for (final state in NmtState.values) {
        if (state == NmtState.unknown) continue;
        expect(NmtStateExt.fromByte(state.stateByte), state);
      }
    });
  });

  group('NmtCommand', () {
    test('byte values are correct', () {
      expect(NmtCommand.start.byte, 0x01);
      expect(NmtCommand.stop.byte, 0x02);
      expect(NmtCommand.enterPreOperational.byte, 0x80);
      expect(NmtCommand.resetNode.byte, 0x81);
      expect(NmtCommand.resetCommunication.byte, 0x82);
    });
  });

  group('LssMode', () {
    test('byte values are correct', () {
      expect(LssMode.operation.byte, 0x00);
      expect(LssMode.configuration.byte, 0x01);
    });
  });
}
