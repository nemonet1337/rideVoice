import 'dart:typed_data';

/// E2E crypto surface (design doc §4-4): X25519 key exchange, HKDF-SHA256
/// key derivation, AES-256-GCM sealing with associated data.
///
/// The production target is the Rust rv-crypto crate over FFI; the pure
/// Dart implementation (DartCryptoProvider) is parameter-compatible so
/// either side can decrypt the other's output.
abstract class CryptoProvider {
  Future<KeyPair> generateKeyPair();

  /// X25519 ECDH. Throws on a low-order peer key (all-zero shared secret).
  Future<Uint8List> ecdh(Uint8List privateKey, Uint8List peerPublicKey);

  /// HKDF-SHA256 with info "ridevoice-session-key", 32-byte output.
  Future<Uint8List> deriveKey(Uint8List sharedSecret, Uint8List salt);

  /// AES-256-GCM. Returns ciphertext || 16-byte tag (matching rv-crypto).
  Future<Uint8List> encrypt(
    Uint8List plaintext,
    Uint8List key,
    Uint8List nonce, {
    Uint8List? aad,
  });

  /// Throws [AuthenticationException] when the tag or AAD does not verify.
  Future<Uint8List> decrypt(
    Uint8List ciphertext,
    Uint8List key,
    Uint8List nonce, {
    Uint8List? aad,
  });

  Future<Uint8List> generateNonce();
}

class KeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;

  KeyPair({required this.privateKey, required this.publicKey});
}

class AuthenticationException implements Exception {
  final String message;
  AuthenticationException(this.message);
  @override
  String toString() => 'AuthenticationException: $message';
}

String hexEncode(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List hexDecode(String hex) {
  if (hex.length.isOdd) {
    throw const FormatException('Odd-length hex string');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
