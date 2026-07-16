import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/crypto/crypto.dart';
import 'package:ridevoice/crypto/dart_crypto_provider.dart';
import 'package:ridevoice/crypto/group_crypto.dart';
import 'package:ridevoice/mesh/packet.dart';

void main() {
  final provider = DartCryptoProvider();

  Uint8List bytes(int filler, [int length = 32]) =>
      Uint8List.fromList(List.filled(length, filler));

  group('DartCryptoProvider primitives', () {
    test('ECDH agreement between two fresh keypairs', () async {
      final alice = await provider.generateKeyPair();
      final bob = await provider.generateKeyPair();

      final sharedA = await provider.ecdh(alice.privateKey, bob.publicKey);
      final sharedB = await provider.ecdh(bob.privateKey, alice.publicKey);
      expect(sharedA, sharedB);
      expect(sharedA.length, 32);
    });

    test('ECDH rejects a low-order (all-zero) peer key', () async {
      final kp = await provider.generateKeyPair();
      expect(
        () => provider.ecdh(kp.privateKey, Uint8List(32)),
        throwsA(isA<AuthenticationException>()),
      );
    });

    /// RFC 7748 §6.1 X25519 vector — must match rv-crypto
    /// (rust/rv-crypto/src/key_exchange.rs).
    test('X25519 matches the RFC 7748 test vector', () async {
      final alicePriv = hexDecode(
          '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
      final bobPub = hexDecode(
          'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
      final shared = await provider.ecdh(alicePriv, bobPub);
      expect(
        hexEncode(shared),
        '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742',
      );
    });

    /// Cross-language vector pinned in rv-crypto
    /// (test_derive_session_key_cross_language_vector).
    test('HKDF session key matches the Rust implementation', () async {
      final sk = await provider.deriveKey(
        bytes(0x01),
        Uint8List.fromList(utf8.encode('ridevoice-salt')),
      );
      expect(
        hexEncode(sk),
        'c20c672dcdd673cb2d6f47aceaa9e796abb40c8c593671c6109e8af622f7d736',
      );
    });

    /// Cross-language AES-256-GCM vector pinned in rv-crypto
    /// (test_cross_language_interop_vector).
    test('AES-GCM output matches the Rust implementation', () async {
      final nonce = NonceSequence(7, counter: 5).nextNonce();
      expect(hexEncode(nonce), '000000070000000000000005');

      final sealed = await provider.encrypt(
        Uint8List.fromList(utf8.encode('ridevoice-frame')),
        bytes(0x02),
        nonce,
        aad: Uint8List.fromList(utf8.encode('src=7;seq=5;epoch=1')),
      );
      expect(
        hexEncode(sealed),
        '58ba36989a570f749eb2bf6198a52ec26a087dabd216aac4f6115398955cb9',
      );
    });

    test('encrypt/decrypt roundtrip with AAD', () async {
      final key = bytes(0x11);
      final nonce = await provider.generateNonce();
      final aad = Uint8List.fromList(utf8.encode('header'));
      final plaintext = Uint8List.fromList(utf8.encode('voice payload'));

      final sealed = await provider.encrypt(plaintext, key, nonce, aad: aad);
      expect(sealed.length, plaintext.length + 16);

      final opened = await provider.decrypt(sealed, key, nonce, aad: aad);
      expect(opened, plaintext);
    });

    test('tampered ciphertext fails authentication', () async {
      final key = bytes(0x11);
      final nonce = await provider.generateNonce();
      final sealed = await provider.encrypt(bytes(0x22, 40), key, nonce);
      sealed[0] ^= 0x01;
      expect(
        () => provider.decrypt(sealed, key, nonce),
        throwsA(isA<AuthenticationException>()),
      );
    });

    test('wrong AAD fails authentication', () async {
      final key = bytes(0x11);
      final nonce = await provider.generateNonce();
      final sealed = await provider.encrypt(
        bytes(0x22, 40),
        key,
        nonce,
        aad: Uint8List.fromList(utf8.encode('src=1')),
      );
      expect(
        () => provider.decrypt(sealed, key, nonce,
            aad: Uint8List.fromList(utf8.encode('src=2'))),
        throwsA(isA<AuthenticationException>()),
      );
    });

    test('truncated ciphertext is rejected', () async {
      final key = bytes(0x11);
      final nonce = await provider.generateNonce();
      final sealed = await provider.encrypt(bytes(0x22, 40), key, nonce);
      expect(
        () => provider.decrypt(
            sealed.sublist(0, sealed.length - 1), key, nonce),
        throwsA(isA<AuthenticationException>()),
      );
      expect(
        () => provider.decrypt(Uint8List(8), key, nonce),
        throwsA(isA<AuthenticationException>()),
      );
    });
  });

  group('NonceSequence', () {
    test('is deterministic, monotonic, and sender-partitioned', () {
      final seqA = NonceSequence(1);
      final seqB = NonceSequence(2);
      final seen = <String>{};
      for (var i = 0; i < 1000; i++) {
        expect(seen.add(hexEncode(seqA.nextNonce())), isTrue);
        expect(seen.add(hexEncode(seqB.nextNonce())), isTrue);
      }
      expect(seqA.counter, 1000);
    });
  });

  group('GroupKeyRing', () {
    test('rotation keeps one previous generation (§4-3 grace period)', () {
      final ring = GroupKeyRing(GroupKeyData(bytes(0xA0), 0));
      ring.rotate(bytes(0xA1));
      expect(ring.current.epoch, 1);
      expect(ring.keyForEpoch(0), isNotNull);

      ring.rotate(bytes(0xA2));
      expect(ring.current.epoch, 2);
      expect(ring.keyForEpoch(0), isNull, reason: '2 generations back');
      expect(ring.keyForEpoch(1), isNotNull);
      expect(ring.keyForEpoch(3), isNull);
    });

    test('install rejects stale or same-epoch keys', () {
      final ring = GroupKeyRing(GroupKeyData(bytes(0xA0), 1));
      expect(() => ring.install(GroupKeyData(bytes(0xA1), 0)),
          throwsStateError);
      expect(() => ring.install(GroupKeyData(bytes(0xA1), 1)),
          throwsStateError);
      ring.install(GroupKeyData(bytes(0xA1), 2));
      expect(ring.current.epoch, 2);
    });
  });

  group('GroupVoiceCrypto', () {
    MeshPacket draft(int srcId, int seq, int epoch, Uint8List payload) =>
        MeshPacket(
          type: PacketType.voice,
          srcId: srcId,
          dstId: broadcastId,
          seqNum: seq,
          hopCount: 4,
          timestampMs: 12345,
          keyEpoch: epoch,
          payload: payload,
        );

    test('seal/open roundtrip through a MeshPacket', () async {
      final gk = bytes(0x33);
      final sender = GroupVoiceCrypto(
        provider: provider,
        keyRing: GroupKeyRing(GroupKeyData(gk, 0)),
        senderId: 1,
      );
      final receiver = GroupVoiceCrypto(
        provider: provider,
        keyRing: GroupKeyRing(GroupKeyData(gk, 0)),
        senderId: 2,
      );

      final plaintext = bytes(0x55, 80);
      final unsealed = draft(1, 10, sender.currentEpoch, plaintext);
      final sealed = await sender.seal(plaintext, unsealed.aadBytes());
      final packet = unsealed.copyWith(
        nonce: sealed.nonce,
        authTag: sealed.authTag,
        payload: sealed.ciphertext,
      );

      expect(await receiver.open(packet), plaintext);
    });

    test('previous-epoch packets still open during rotation', () async {
      final gk0 = bytes(0x33);
      final senderRing = GroupKeyRing(GroupKeyData(gk0, 0));
      final receiverRing = GroupKeyRing(GroupKeyData(gk0, 0));
      final sender = GroupVoiceCrypto(
          provider: provider, keyRing: senderRing, senderId: 1);
      final receiver = GroupVoiceCrypto(
          provider: provider, keyRing: receiverRing, senderId: 2);

      // Seal at epoch 0.
      final plaintext = bytes(0x66, 40);
      final unsealed = draft(1, 11, 0, plaintext);
      final sealed = await sender.seal(plaintext, unsealed.aadBytes());
      final packet = unsealed.copyWith(
        nonce: sealed.nonce,
        authTag: sealed.authTag,
        payload: sealed.ciphertext,
      );

      // Receiver rotates before the packet arrives.
      receiverRing.install(GroupKeyData(bytes(0x44), 1));
      expect(await receiver.open(packet), plaintext,
          reason: 'grace period: previous epoch must still decrypt');
    });

    test('unknown epoch and wrong key are rejected', () async {
      final sender = GroupVoiceCrypto(
        provider: provider,
        keyRing: GroupKeyRing(GroupKeyData(bytes(0x33), 0)),
        senderId: 1,
      );
      final strangerKey = GroupVoiceCrypto(
        provider: provider,
        keyRing: GroupKeyRing(GroupKeyData(bytes(0x99), 0)),
        senderId: 3,
      );

      final plaintext = bytes(0x77, 40);
      final unsealed = draft(1, 12, 0, plaintext);
      final sealed = await sender.seal(plaintext, unsealed.aadBytes());
      final packet = unsealed.copyWith(
        nonce: sealed.nonce,
        authTag: sealed.authTag,
        payload: sealed.ciphertext,
      );

      expect(await strangerKey.open(packet), isNull,
          reason: 'wrong group key must fail');
      expect(await sender.open(packet.copyWith(keyEpoch: 5)), isNull,
          reason: 'unknown epoch must fail');
    });

    test('re-attributed src (AAD tamper) is rejected', () async {
      final gk = bytes(0x33);
      final sender = GroupVoiceCrypto(
        provider: provider,
        keyRing: GroupKeyRing(GroupKeyData(gk, 0)),
        senderId: 1,
      );
      final receiver = GroupVoiceCrypto(
        provider: provider,
        keyRing: GroupKeyRing(GroupKeyData(gk, 0)),
        senderId: 2,
      );

      final plaintext = bytes(0x88, 40);
      final unsealed = draft(1, 13, 0, plaintext);
      final sealed = await sender.seal(plaintext, unsealed.aadBytes());

      // A malicious relay rewrites the source ID.
      final forged = MeshPacket(
        type: PacketType.voice,
        srcId: 999,
        dstId: broadcastId,
        seqNum: 13,
        hopCount: 4,
        timestampMs: 12345,
        keyEpoch: 0,
        nonce: sealed.nonce,
        authTag: sealed.authTag,
        payload: sealed.ciphertext,
      );
      expect(await receiver.open(forged), isNull);
    });
  });
}
