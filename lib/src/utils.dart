/// Utility functions for encoding/decoding CAN frame payloads.
library;

import 'dart:convert';
import 'dart:typed_data';

// ── Encode helpers ────────────────────────────────────────────────────────────

/// Encodes an unsigned 16-bit integer as 2 little-endian bytes.
///
/// Example: `encodeU16LE(0x1234)` → `[0x34, 0x12]`
Uint8List encodeU16LE(int value) {
  final buf = ByteData(2);
  buf.setUint16(0, value & 0xFFFF, Endian.little);
  return buf.buffer.asUint8List();
}

/// Encodes an unsigned 32-bit integer as 4 little-endian bytes.
///
/// Example: `encodeU32LE(0x12345678)` → `[0x78, 0x56, 0x34, 0x12]`
Uint8List encodeU32LE(int value) {
  final buf = ByteData(4);
  buf.setUint32(0, value & 0xFFFFFFFF, Endian.little);
  return buf.buffer.asUint8List();
}

/// Encodes a 32-bit IEEE 754 float as 4 little-endian bytes.
Uint8List encodeF32LE(double value) {
  final buf = ByteData(4);
  buf.setFloat32(0, value, Endian.little);
  return buf.buffer.asUint8List();
}

/// Encodes a 64-bit IEEE 754 double as 8 little-endian bytes.
Uint8List encodeF64LE(double value) {
  final buf = ByteData(8);
  buf.setFloat64(0, value, Endian.little);
  return buf.buffer.asUint8List();
}

/// Encodes a UTF-8 string to bytes (not null-terminated).
Uint8List encodeString(String value) => Uint8List.fromList(utf8.encode(value));

// ── Decode helpers ─────────────────────────────────────────────────────────

/// Decodes a little-endian unsigned 8-bit integer from [data] at [offset].
int decodeU8(Uint8List data, [int offset = 0]) => data[offset];

/// Decodes a little-endian unsigned 16-bit integer from [data] at [offset].
///
/// Example: `decodeU16LE([0x34, 0x12], 0)` → `0x1234`
int decodeU16LE(Uint8List data, [int offset = 0]) =>
    ByteData.sublistView(data, offset, offset + 2).getUint16(0, Endian.little);

/// Decodes a little-endian unsigned 32-bit integer from [data] at [offset].
///
/// Example: `decodeU32LE([0x78, 0x56, 0x34, 0x12], 0)` → `0x12345678`
int decodeU32LE(Uint8List data, [int offset = 0]) =>
    ByteData.sublistView(data, offset, offset + 4).getUint32(0, Endian.little);

/// Decodes a little-endian 32-bit float from [data] at [offset].
double decodeF32LE(Uint8List data, [int offset = 0]) =>
    ByteData.sublistView(data, offset, offset + 4).getFloat32(0, Endian.little);

/// Decodes a little-endian 64-bit double from [data] at [offset].
double decodeF64LE(Uint8List data, [int offset = 0]) =>
    ByteData.sublistView(data, offset, offset + 8).getFloat64(0, Endian.little);

/// Decodes a null-terminated UTF-8 string from [data].
///
/// Stops at the first `0x00` byte, or uses the entire buffer if none found.
String decodeString(Uint8List data) {
  final end = data.indexOf(0);
  final bytes = end >= 0 ? data.sublist(0, end) : data;
  return utf8.decode(bytes, allowMalformed: true);
}

// ── Padding helpers ───────────────────────────────────────────────────────────

/// Returns a zero-padded copy of [data] guaranteed to be exactly [length] bytes.
///
/// If [data] is already [length] bytes or longer, it is returned unchanged
/// (sublist taken if longer).
Uint8List padTo(Uint8List data, int length) {
  if (data.length == length) return data;
  if (data.length > length) return data.sublist(0, length);
  final out = Uint8List(length);
  out.setRange(0, data.length, data);
  return out;
}
