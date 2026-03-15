import 'dart:typed_data';

import 'package:canopen_client/src/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('encodeU16LE / decodeU16LE', () {
    test('round-trips 0x1234', () {
      final encoded = encodeU16LE(0x1234);
      expect(encoded, [0x34, 0x12]);
      expect(decodeU16LE(encoded), 0x1234);
    });

    test('round-trips 0x0000', () {
      final encoded = encodeU16LE(0x0000);
      expect(encoded, [0x00, 0x00]);
      expect(decodeU16LE(encoded), 0x0000);
    });

    test('round-trips 0xFFFF', () {
      final encoded = encodeU16LE(0xFFFF);
      expect(encoded, [0xFF, 0xFF]);
      expect(decodeU16LE(encoded), 0xFFFF);
    });

    test('encodes 1000 as [0xE8, 0x03]', () {
      expect(encodeU16LE(1000), [0xE8, 0x03]);
    });

    test('decodes with non-zero offset', () {
      final data = Uint8List.fromList([0x00, 0x34, 0x12, 0x00]);
      expect(decodeU16LE(data, 1), 0x1234);
    });
  });

  group('encodeU32LE / decodeU32LE', () {
    test('round-trips 0x12345678', () {
      final encoded = encodeU32LE(0x12345678);
      expect(encoded, [0x78, 0x56, 0x34, 0x12]);
      expect(decodeU32LE(encoded), 0x12345678);
    });

    test('round-trips 0x00000000', () {
      expect(decodeU32LE(encodeU32LE(0)), 0);
    });

    test('round-trips 0xFFFFFFFF', () {
      expect(decodeU32LE(encodeU32LE(0xFFFFFFFF)), 0xFFFFFFFF);
    });

    test('decodes with offset', () {
      final data = Uint8List.fromList([0x00, 0x78, 0x56, 0x34, 0x12]);
      expect(decodeU32LE(data, 1), 0x12345678);
    });
  });

  group('encodeF32LE / decodeF32LE', () {
    test('round-trips 1.0f within float32 precision', () {
      final encoded = encodeF32LE(1.0);
      final decoded = decodeF32LE(encoded);
      expect(decoded, closeTo(1.0, 1e-6));
    });

    test('round-trips -3.14f within float32 precision', () {
      final encoded = encodeF32LE(-3.14);
      final decoded = decodeF32LE(encoded);
      expect(decoded, closeTo(-3.14, 1e-5));
    });
  });

  group('decodeU8', () {
    test('returns single byte', () {
      final data = Uint8List.fromList([0xAB, 0xCD]);
      expect(decodeU8(data, 0), 0xAB);
      expect(decodeU8(data, 1), 0xCD);
    });
  });

  group('decodeString', () {
    test('decodes null-terminated ASCII string', () {
      final data =
          Uint8List.fromList([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x00, 0xFF]);
      expect(decodeString(data), 'Hello');
    });

    test('decodes string without null terminator', () {
      final data = Uint8List.fromList([0x48, 0x69]);
      expect(decodeString(data), 'Hi');
    });

    test('returns empty string for empty data', () {
      expect(decodeString(Uint8List(0)), '');
    });
  });

  group('encodeString', () {
    test('encodes ASCII string to bytes', () {
      final encoded = encodeString('Hi');
      expect(encoded, [0x48, 0x69]);
    });
  });

  group('padTo', () {
    test('pads short data with zeros', () {
      final data = Uint8List.fromList([0x01, 0x02]);
      final padded = padTo(data, 4);
      expect(padded, [0x01, 0x02, 0x00, 0x00]);
    });

    test('returns data unchanged if already correct length', () {
      final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04]);
      expect(padTo(data, 4), [0x01, 0x02, 0x03, 0x04]);
    });

    test('truncates data longer than requested length', () {
      final data = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
      expect(padTo(data, 4), [0x01, 0x02, 0x03, 0x04]);
    });
  });
}
