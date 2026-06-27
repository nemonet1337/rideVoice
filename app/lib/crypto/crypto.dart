import 'dart:typed_data';

abstract class CryptoProvider {
  Future<KeyPair> generateKeyPair();
  Future<Uint8List> ecdh(Uint8List privateKey, Uint8List peerPublicKey);
  Future<Uint8List> deriveKey(Uint8List sharedSecret, Uint8List salt);
  Future<Uint8List> encrypt(Uint8List plaintext, Uint8List key, Uint8List nonce);
  Future<Uint8List> decrypt(Uint8List ciphertext, Uint8List key, Uint8List nonce);
  Future<Uint8List> generateNonce();
}

class KeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;

  KeyPair({required this.privateKey, required this.publicKey});
}
