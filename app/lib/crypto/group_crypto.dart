import 'dart:typed_data';

import '../mesh/aodv.dart';
import '../mesh/packet.dart';
import 'crypto.dart';

/// Group key material with its rotation epoch (mirrors rv-crypto GroupKey).
class GroupKeyData {
  final Uint8List keyBytes;
  final int epoch;

  GroupKeyData(this.keyBytes, this.epoch) {
    if (keyBytes.length != 32) {
      throw ArgumentError('group key must be 32 bytes');
    }
    if (epoch < 0 || epoch > 0xFFFFFFFF) {
      throw ArgumentError('epoch out of range: $epoch');
    }
  }
}

/// Current + previous group key (mirrors rv-crypto KeyRing).
///
/// Rotation is not atomic across the mesh (design doc §13): packets sealed
/// with the previous generation must still open while the new key
/// propagates; anything older is rejected.
class GroupKeyRing {
  GroupKeyData _current;
  GroupKeyData? _previous;

  GroupKeyRing(this._current);

  GroupKeyData get current => _current;

  /// Host-side rotation with fresh key material.
  void rotate(Uint8List newKeyBytes) {
    _previous = _current;
    _current = GroupKeyData(newKeyBytes, _current.epoch + 1);
  }

  /// Installs a key received from the cluster head. Stale or same-epoch
  /// keys are rejected.
  void install(GroupKeyData key) {
    if (key.epoch <= _current.epoch) {
      throw StateError(
          'stale group key: epoch ${key.epoch} <= current ${_current.epoch}');
    }
    _previous = _current;
    _current = key;
  }

  GroupKeyData? keyForEpoch(int epoch) {
    if (epoch == _current.epoch) return _current;
    final prev = _previous;
    if (prev != null && prev.epoch == epoch) return prev;
    return null;
  }
}

/// Deterministic 96-bit nonce: 4-byte sender ID || 8-byte counter
/// (mirrors rv-crypto NonceSequence). Distinct sender IDs partition the
/// nonce space so all group members can seal with the same GK.
class NonceSequence {
  final int senderId;
  int _counter;

  NonceSequence(this.senderId, {int counter = 0}) : _counter = counter;

  int get counter => _counter;

  Uint8List nextNonce() {
    final nonce = Uint8List(12);
    final data = ByteData.view(nonce.buffer);
    data.setUint32(0, senderId);
    data.setUint32(4, (_counter >> 32) & 0xFFFFFFFF);
    data.setUint32(8, _counter & 0xFFFFFFFF);
    _counter++;
    return nonce;
  }
}

/// Voice-packet encryption for the mesh (design doc §2-1, §4-2):
/// AES-256-GCM under the group key, header bound as AAD, deterministic
/// per-sender nonces, and epoch-based key lookup during rotation.
class GroupVoiceCrypto implements VoicePacketCrypto {
  final CryptoProvider provider;
  final GroupKeyRing keyRing;
  final NonceSequence nonceSequence;

  GroupVoiceCrypto({
    required this.provider,
    required this.keyRing,
    required int senderId,
  }) : nonceSequence = NonceSequence(senderId);

  @override
  int get currentEpoch => keyRing.current.epoch;

  @override
  Future<SealedVoice> seal(Uint8List plaintext, Uint8List aad) async {
    final nonce = nonceSequence.nextNonce();
    final sealed = await provider.encrypt(
      plaintext,
      keyRing.current.keyBytes,
      nonce,
      aad: aad,
    );
    final split = sealed.length - MeshPacket.tagLength;
    return SealedVoice(
      nonce: nonce,
      authTag: sealed.sublist(split),
      ciphertext: sealed.sublist(0, split),
    );
  }

  @override
  Future<Uint8List?> open(MeshPacket packet) async {
    final key = keyRing.keyForEpoch(packet.keyEpoch);
    if (key == null) return null;

    final combined = Uint8List(packet.payload.length + packet.authTag.length)
      ..setRange(0, packet.payload.length, packet.payload)
      ..setRange(packet.payload.length,
          packet.payload.length + packet.authTag.length, packet.authTag);
    try {
      return await provider.decrypt(
        combined,
        key.keyBytes,
        packet.nonce,
        aad: packet.aadBytes(),
      );
    } on AuthenticationException {
      return null;
    }
  }
}
