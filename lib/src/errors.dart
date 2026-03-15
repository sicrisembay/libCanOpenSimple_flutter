/// Exception types for the CANopen client library.
library;

// ── Base Exception ────────────────────────────────────────────────────────────

/// Base class for all CANopen exceptions thrown by this library.
class CanOpenException implements Exception {
  /// Creates a [CanOpenException] with a descriptive [message].
  const CanOpenException(this.message);

  /// Human-readable description of the error.
  final String message;

  @override
  String toString() => 'CanOpenException: $message';
}

// ── SDO Exceptions ────────────────────────────────────────────────────────────

/// Thrown when a remote node aborts an SDO transfer.
///
/// The [abortCode] follows the SDO abort code table defined in CiA 301 §7.2.4.
class SdoAbortException extends CanOpenException {
  /// Creates an [SdoAbortException] with the 4-byte SDO [abortCode].
  SdoAbortException(this.abortCode)
      : super(
            'SDO transfer aborted with code 0x${abortCode.toRadixString(16)}');

  /// The 4-byte SDO abort code from the remote node.
  final int abortCode;

  /// Returns a human-readable description of the abort code.
  String get description => _describeAbortCode(abortCode);

  @override
  String toString() =>
      'SdoAbortException: 0x${abortCode.toRadixString(16).toUpperCase().padLeft(8, '0')} — $description';

  static String _describeAbortCode(int code) => switch (code) {
        0x05030000 => 'Toggle bit not alternated',
        0x05040000 => 'SDO protocol timed out',
        0x05040001 => 'Client/server command specifier not valid or unknown',
        0x05040002 => 'Invalid block size',
        0x05040003 => 'Invalid sequence number',
        0x05040004 => 'CRC error',
        0x05040005 => 'Out of memory',
        0x06010000 => 'Unsupported access to an object',
        0x06010001 => 'Attempt to read a write-only object',
        0x06010002 => 'Attempt to write a read-only object',
        0x06020000 => 'Object does not exist in the object dictionary',
        0x06040041 => 'Object cannot be mapped to PDO',
        0x06040042 =>
          'Number and length of mapped objects would exceed PDO length',
        0x06040043 => 'General parameter incompatibility',
        0x06040047 => 'General internal incompatibility in the device',
        0x06060000 => 'Access failed due to a hardware error',
        0x06070010 =>
          'Data type does not match, length of service parameter does not match',
        0x06070012 => 'Data type does not match, length too high',
        0x06070013 => 'Data type does not match, length too low',
        0x06090011 => 'Sub-index does not exist',
        0x06090030 => 'Value range of parameter exceeded',
        0x06090031 => 'Value of parameter written too high',
        0x06090032 => 'Value of parameter written too low',
        0x06090036 => 'Maximum value is less than minimum value',
        0x060A0023 => 'Resource not available',
        0x08000000 => 'General error',
        0x08000020 => 'Data cannot be transferred or stored to application',
        0x08000021 => 'Data cannot be transferred (local control)',
        0x08000022 => 'Data cannot be transferred (device state)',
        0x08000023 =>
          'Object dictionary not present or dynamic generation failed',
        0x08000024 => 'No data available',
        _ => 'Unknown abort code',
      };
}

// ── Timeout Exception ─────────────────────────────────────────────────────────

/// Thrown when a CANopen operation does not receive a response within the
/// configured timeout period.
class CanOpenTimeoutException extends CanOpenException {
  /// Creates a [CanOpenTimeoutException].
  ///
  /// [operation] should describe what was attempted, e.g. `'SDO read 0x1000/0'`.
  const CanOpenTimeoutException(String operation)
      : super('Timeout waiting for response to: $operation');

  @override
  String toString() => 'CanOpenTimeoutException: $message';
}

// ── LSS Exception ─────────────────────────────────────────────────────────────

/// Thrown when an LSS operation fails or the remote slave returns an error.
class LssException extends CanOpenException {
  /// Creates an [LssException] with the raw LSS [errorCode] byte.
  const LssException(this.errorCode) : super('LSS error code: $errorCode');

  /// Raw 1-byte LSS error code from the slave response.
  final int errorCode;

  @override
  String toString() =>
      'LssException: code=0x${errorCode.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}

// ── Hardware Exception ────────────────────────────────────────────────────────

/// Thrown when a CAN hardware or serial port operation fails.
class HardwareException extends CanOpenException {
  /// Creates a [HardwareException] with a [message] describing the failure.
  const HardwareException(super.message);

  @override
  String toString() => 'HardwareException: $message';
}
