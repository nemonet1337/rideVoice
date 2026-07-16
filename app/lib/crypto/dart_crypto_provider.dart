import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as c;

import 'crypto.dart';

/// Pure-Dart [CryptoProvider] built on package:cryptography.
///
/// Parameter-compatible with the Rust rv-crypto crate (X25519, HKDF-SHA256
/// with info "ridevoice-session-key", AES-256-GCM emitting
/// ciphertext || tag) — see the cross-language vectors in
/// test/crypto_test.dart and rust/rv-crypto/src/seal.rs.
class DartCryptoProvider implements CryptoProvider {
  static const String sessionKeyInfo = 'ridevoice-session-key';
  static const int tagLength = 16;

  final c.X25519 _x25519 = c.X25519();
  final c.AesGcm _aesGcm = c.AesGcm.with256bits();
  final Random _random = Random.secure();

  @override
  Future<KeyPair> generateKeyPair() async {
    final keyPair = await _x25519.newKeyPair();
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final publicKey = (await keyPair.extractPublicKey()).bytes;
    return KeyPair(
      privateKey: Uint8List.fromList(privateKey),
      publicKey: Uint8List.fromList(publicKey),
    );
  }

  @override
  Future<Uint8List> ecdh(Uint8List privateKey, Uint8List peerPublicKey) async {
    final keyPair = await _x25519.newKeyPairFromSeed(privateKey);
    final shared = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: c.SimplePublicKey(
        peerPublicKey,
        type: c.KeyPairType.x25519,
      ),
    );
    final bytes = Uint8List.fromList(await shared.extractBytes());
    if (bytes.every((b) => b == 0)) {
      throw AuthenticationException(
          'ECDH produced an all-zero shared secret (low-order peer key)');
    }
    return bytes;
  }

  @override
  Future<Uint8List> deriveKey(Uint8List sharedSecret, Uint8List salt) async {
    final hkdf = c.Hkdf(hmac: c.Hmac.sha256(), outputLength: 32);
    final okm = await hkdf.deriveKey(
      secretKey: c.SecretKey(sharedSecret),
      nonce: salt,
      info: utf8.encode(sessionKeyInfo),
    );
    return Uint8List.fromList(await okm.extractBytes());
  }

  @override
  Future<Uint8List> encrypt(
    Uint8List plaintext,
    Uint8List key,
    Uint8List nonce, {
    Uint8List? aad,
  }) async {
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: c.SecretKey(key),
      nonce: nonce,
      aad: aad ?? const [],
    );
    final out = Uint8List(box.cipherText.length + box.mac.bytes.length);
    out.setRange(0, box.cipherText.length, box.cipherText);
    out.setRange(box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  @override
  Future<Uint8List> decrypt(
    Uint8List ciphertext,
    Uint8List key,
    Uint8List nonce, {
    Uint8List? aad,
  }) async {
    if (ciphertext.length < tagLength) {
      throw AuthenticationException('ciphertext shorter than the GCM tag');
    }
    final split = ciphertext.length - tagLength;
    final box = c.SecretBox(
      ciphertext.sublist(0, split),
      nonce: nonce,
      mac: c.Mac(ciphertext.sublist(split)),
    );
    try {
      final clear = await _aesGcm.decrypt(
        box,
        secretKey: c.SecretKey(key),
        aad: aad ?? const [],
      );
      return Uint8List.fromList(clear);
    } on c.SecretBoxAuthenticationError {
      throw AuthenticationException('AES-GCM authentication failed');
    }
  }

  @override
  Future<Uint8List> generateNonce() async {
    final nonce = Uint8List(12);
    for (var i = 0; i < nonce.length; i++) {
      nonce[i] = _random.nextInt(256);
    }
    return nonce;
  }
}
