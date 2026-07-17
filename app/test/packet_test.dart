import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/mesh/packet.dart';

void main() {
  MeshPacket samplePacket({int hopCount = 4}) => MeshPacket(
        type: PacketType.voice,
        srcId: 0x01020304,
        dstId: 0xA1B2C3D4,
        seqNum: 0xBEEF,
        hopCount: hopCount,
        timestampMs: 1721000000123,
        keyEpoch: 7,
        nonce: Uint8List.fromList(List.generate(12, (i) => i + 1)),
        authTag: Uint8List.fromList(List.generate(16, (i) => 0x40 + i)),
        payload: Uint8List.fromList(List.generate(80, (i) => i)),
      );

  group('MeshPacket encode/decode', () {
    test('roundtrip preserves every field', () {
      final packet = samplePacket();
      final decoded = MeshPacket.decode(packet.encode());

      expect(decoded.type, PacketType.voice);
      expect(decoded.srcId, 0x01020304);
      expect(decoded.dstId, 0xA1B2C3D4);
      expect(decoded.seqNum, 0xBEEF);
      expect(decoded.hopCount, 4);
      expect(decoded.timestampMs, 1721000000123);
      expect(decoded.keyEpoch, 7);
      expect(decoded.nonce, packet.nonce);
      expect(decoded.authTag, packet.authTag);
      expect(decoded.payload, packet.payload);
    });

    test('header layout matches the design doc §3-4 offsets', () {
      final bytes = samplePacket().encode();
      expect(bytes.length, MeshPacket.headerLength + 80);
      // src_id big-endian at offset 1 (after the type byte).
      expect(bytes.sublist(1, 5), [0x01, 0x02, 0x03, 0x04]);
      // dst_id at offset 5.
      expect(bytes.sublist(5, 9), [0xA1, 0xB2, 0xC3, 0xD4]);
      // seq_num at offset 9.
      expect(bytes.sublist(9, 11), [0xBE, 0xEF]);
      // hop_count at offset 11.
      expect(bytes[11], 4);
      // nonce 12 bytes at offset 24, auth_tag 16 bytes at offset 36.
      expect(bytes.sublist(24, 36), List.generate(12, (i) => i + 1));
      expect(bytes.sublist(36, 52), List.generate(16, (i) => 0x40 + i));
    });

    test('empty payload roundtrip', () {
      final packet = MeshPacket(
        type: PacketType.heartbeat,
        srcId: 1,
        dstId: broadcastId,
        seqNum: 0,
        hopCount: 1,
        timestampMs: 0,
      );
      final decoded = MeshPacket.decode(packet.encode());
      expect(decoded.payload, isEmpty);
      expect(decoded.isBroadcast, isTrue);
    });

    test('rejects truncated packets', () {
      final bytes = samplePacket().encode();
      expect(
        () => MeshPacket.decode(bytes.sublist(0, MeshPacket.headerLength - 1)),
        throwsFormatException,
      );
      expect(() => MeshPacket.decode(Uint8List(0)), throwsFormatException);
    });

    test('rejects unknown packet types', () {
      final bytes = samplePacket().encode();
      bytes[0] = 0xEE;
      expect(() => MeshPacket.decode(bytes), throwsFormatException);
    });

    test('rejects out-of-range field values', () {
      expect(
        () => MeshPacket(
          type: PacketType.voice,
          srcId: -1,
          dstId: 0,
          seqNum: 0,
          hopCount: 0,
          timestampMs: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => MeshPacket(
          type: PacketType.voice,
          srcId: 0,
          dstId: 0,
          seqNum: 0x10000,
          hopCount: 0,
          timestampMs: 0,
        ),
        throwsArgumentError,
      );
      expect(
        () => MeshPacket(
          type: PacketType.voice,
          srcId: 0,
          dstId: 0,
          seqNum: 0,
          hopCount: 256,
          timestampMs: 0,
        ),
        throwsArgumentError,
      );
    });

    test('forwarded() decrements only the TTL', () {
      final packet = samplePacket(hopCount: 3);
      final next = packet.forwarded();
      expect(next.hopCount, 2);
      expect(next.srcId, packet.srcId);
      expect(next.seqNum, packet.seqNum);
      expect(next.payload, packet.payload);
    });

    test('AAD excludes the mutable TTL so relayed packets still verify', () {
      final packet = samplePacket(hopCount: 4);
      final relayed = packet.forwarded();
      expect(packet.aadBytes(), relayed.aadBytes());

      // But AAD binds src/seq/epoch.
      final reattributed = MeshPacket(
        type: packet.type,
        srcId: packet.srcId + 1,
        dstId: packet.dstId,
        seqNum: packet.seqNum,
        hopCount: packet.hopCount,
        timestampMs: packet.timestampMs,
        keyEpoch: packet.keyEpoch,
        nonce: packet.nonce,
        authTag: packet.authTag,
        payload: packet.payload,
      );
      expect(packet.aadBytes(), isNot(equals(reattributed.aadBytes())));
    });
  });

  group('nodeIdFromString', () {
    test('is deterministic and avoids the broadcast value', () {
      expect(nodeIdFromString('abc'), nodeIdFromString('abc'));
      expect(nodeIdFromString('abc'), isNot(nodeIdFromString('abd')));
      expect(nodeIdFromString('anything'), isNot(broadcastId));
    });
  });
}
