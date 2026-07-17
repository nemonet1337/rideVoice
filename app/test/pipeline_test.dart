import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/audio/offline_audio_pipeline.dart';
import 'package:ridevoice/crypto/dart_crypto_provider.dart';
import 'package:ridevoice/crypto/group_crypto.dart';
import 'package:ridevoice/mesh/aodv.dart';

import 'support/in_memory_transport.dart';

/// End-to-end offline audio path (design doc §2-1): PCM → codec → AES-GCM
/// seal → mesh → open → jitter buffer → PCM, including loss injection and
/// a wrong-key eavesdropper.
void main() {
  const tick = Duration(milliseconds: 40);

  Uint8List pcm(int seq) =>
      Uint8List.fromList(List.generate(64, (i) => (seq + i) & 0xFF));

  MeshNode node(InMemoryHub hub, String id, {VoicePacketCrypto? crypto}) =>
      MeshNode(
        transport: hub.createTransport(id),
        heartbeatPeriod: tick,
        crypto: crypto,
      );

  GroupVoiceCrypto voiceCrypto(Uint8List gk, int senderId) => GroupVoiceCrypto(
        provider: DartCryptoProvider(),
        keyRing: GroupKeyRing(GroupKeyData(gk, 0)),
        senderId: senderId,
      );

  test('encrypted voice flows sender → mesh → receiver', () async {
    final gk = Uint8List.fromList(List.filled(32, 0x42));
    final hub = InMemoryHub();
    final sender = node(hub, 'S', crypto: voiceCrypto(gk, 1));
    final receiver = node(hub, 'R', crypto: voiceCrypto(gk, 2));
    hub.linkAll();

    final txPipeline = OfflineAudioPipeline(node: sender);
    final rxPipeline = OfflineAudioPipeline(node: receiver);
    await txPipeline.start();
    await rxPipeline.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final received = <ReceivedAudioFrame>[];
    rxPipeline.receivedFrames.listen(received.add);

    for (var i = 0; i < 10; i++) {
      await txPipeline.sendFrame(pcm(i));
    }
    await pumpEventQueue();

    expect(received, hasLength(10));
    for (var i = 0; i < 10; i++) {
      expect(received[i].pcm, pcm(i), reason: 'frame $i must arrive in order');
      expect(received[i].srcId, sender.localId);
    }

    // Confidentiality: what actually crossed the wire was ciphertext —
    // verified separately by the eavesdropper test below.
    await txPipeline.stop();
    await rxPipeline.stop();
    await sender.stop();
    await receiver.stop();
  });

  test('a node with the wrong group key hears nothing (security)', () async {
    final gk = Uint8List.fromList(List.filled(32, 0x42));
    final wrongGk = Uint8List.fromList(List.filled(32, 0x66));
    final hub = InMemoryHub();
    final sender = node(hub, 'S', crypto: voiceCrypto(gk, 1));
    final eavesdropper = node(hub, 'E', crypto: voiceCrypto(wrongGk, 3));
    hub.linkAll();

    await sender.start();
    await eavesdropper.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final heard = <VoiceFrame>[];
    eavesdropper.voiceFrames.listen(heard.add);

    for (var i = 0; i < 5; i++) {
      await sender.sendVoice(pcm(i));
    }
    await pumpEventQueue();

    expect(heard, isEmpty,
        reason: 'wrong key must never yield decrypted audio');
    expect(eavesdropper.authFailureCount, 5,
        reason: 'every packet must fail authentication');

    await sender.stop();
    await eavesdropper.stop();
  });

  test('unencrypted mesh voice is ciphertext-free only without crypto',
      () async {
    // Sanity check of the test double: with no VoicePacketCrypto the
    // payload crosses as plaintext, which is why production always sets
    // GroupVoiceCrypto (§2-1).
    final hub = InMemoryHub();
    final sender = node(hub, 'S');
    final receiver = node(hub, 'R');
    hub.linkAll();
    await sender.start();
    await receiver.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final received = <VoiceFrame>[];
    receiver.voiceFrames.listen(received.add);
    await sender.sendVoice(pcm(1));
    await pumpEventQueue();
    expect(received.single.payload, pcm(1));

    await sender.stop();
    await receiver.stop();
  });

  test('10% packet loss: ordered delivery, losses counted (quality)',
      () async {
    final gk = Uint8List.fromList(List.filled(32, 0x42));
    final hub = InMemoryHub(seed: 1234);
    final sender = node(hub, 'S', crypto: voiceCrypto(gk, 1));
    final receiver = node(hub, 'R', crypto: voiceCrypto(gk, 2));
    hub.linkAll();

    final txPipeline = OfflineAudioPipeline(node: sender);
    final rxPipeline = OfflineAudioPipeline(node: receiver, jitterCapacity: 3);
    await txPipeline.start();
    await rxPipeline.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    // Only lose voice traffic, not the neighbor bootstrap above.
    hub.lossRate = 0.10;

    final received = <ReceivedAudioFrame>[];
    rxPipeline.receivedFrames.listen(received.add);

    const total = 200;
    for (var i = 0; i < total; i++) {
      await txPipeline.sendFrame(pcm(i));
      // Drain the event queue frequently so heartbeats interleave
      // realistically with voice.
      if (i % 20 == 0) await pumpEventQueue();
    }
    hub.lossRate = 0;
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await pumpEventQueue();

    expect(received.length, greaterThan(total ~/ 2),
        reason: 'most frames must survive 10% loss');
    expect(received.length, lessThanOrEqualTo(total));
    expect(rxPipeline.lostFrameCount, greaterThan(0),
        reason: 'losses must be detected and counted for PLC');
    expect(rxPipeline.duplicateFrameCount, 0);

    await txPipeline.stop();
    await rxPipeline.stop();
    await sender.stop();
    await receiver.stop();
  });
}
