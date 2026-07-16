import 'dart:typed_data';

/// Packet types carried over the mesh.
///
/// The design doc §3-4 defines the voice packet layout; a leading type
/// byte and the 4-byte group-key epoch are additions required to multiplex
/// AODV control traffic and support key-rotation grace periods (documented
/// in docs/DESIGN_DEVIATIONS.md).
enum PacketType {
  voice(0x01),
  routeRequest(0x02),
  routeReply(0x03),
  routeError(0x04),
  heartbeat(0x05),
  rekey(0x06);

  const PacketType(this.value);
  final int value;

  static PacketType fromValue(int value) {
    for (final t in PacketType.values) {
      if (t.value == value) return t;
    }
    throw FormatException('Unknown packet type: $value');
  }
}

/// Broadcast destination ID.
const int broadcastId = 0xFFFFFFFF;

/// Binary mesh packet (design doc §3-4).
///
/// Layout (big-endian):
/// ```
/// offset  size  field
///      0     1  packet_type
///      1     4  src_id
///      5     4  dst_id        (0xFFFFFFFF = broadcast)
///      9     2  seq_num
///     11     1  hop_count     (remaining TTL)
///     12     8  timestamp     (ms since epoch)
///     20     4  key_epoch     (group key generation)
///     24    12  nonce         (AES-GCM, zero for unencrypted control)
///     36    16  auth_tag      (AES-GCM, zero for unencrypted control)
///     52     n  payload
/// ```
class MeshPacket {
  static const int headerLength = 52;
  static const int aadLength = 24; // type..key_epoch bound as AAD
  static const int nonceLength = 12;
  static const int tagLength = 16;
  static const int maxHops = 4;

  final PacketType type;
  final int srcId;
  final int dstId;
  final int seqNum;
  final int hopCount;
  final int timestampMs;
  final int keyEpoch;
  final Uint8List nonce;
  final Uint8List authTag;
  final Uint8List payload;

  MeshPacket({
    required this.type,
    required this.srcId,
    required this.dstId,
    required this.seqNum,
    required this.hopCount,
    required this.timestampMs,
    this.keyEpoch = 0,
    Uint8List? nonce,
    Uint8List? authTag,
    Uint8List? payload,
  })  : nonce = nonce ?? Uint8List(nonceLength),
        authTag = authTag ?? Uint8List(tagLength),
        payload = payload ?? Uint8List(0) {
    _checkRange('srcId', srcId, 0xFFFFFFFF);
    _checkRange('dstId', dstId, 0xFFFFFFFF);
    _checkRange('seqNum', seqNum, 0xFFFF);
    _checkRange('hopCount', hopCount, 0xFF);
    _checkRange('keyEpoch', keyEpoch, 0xFFFFFFFF);
    if (this.nonce.length != nonceLength) {
      throw ArgumentError('nonce must be $nonceLength bytes');
    }
    if (this.authTag.length != tagLength) {
      throw ArgumentError('authTag must be $tagLength bytes');
    }
  }

  static void _checkRange(String name, int value, int max) {
    if (value < 0 || value > max) {
      throw ArgumentError('$name out of range: $value');
    }
  }

  bool get isBroadcast => dstId == broadcastId;

  Uint8List encode() {
    final buf = Uint8List(headerLength + payload.length);
    final data = ByteData.view(buf.buffer);
    data.setUint8(0, type.value);
    data.setUint32(1, srcId);
    data.setUint32(5, dstId);
    data.setUint16(9, seqNum);
    data.setUint8(11, hopCount);
    data.setUint64(12, timestampMs);
    data.setUint32(20, keyEpoch);
    buf.setRange(24, 36, nonce);
    buf.setRange(36, 52, authTag);
    buf.setRange(headerLength, buf.length, payload);
    return buf;
  }

  static MeshPacket decode(Uint8List bytes) {
    if (bytes.length < headerLength) {
      throw FormatException(
          'Packet too short: ${bytes.length} < $headerLength');
    }
    final data = ByteData.sublistView(bytes);
    return MeshPacket(
      type: PacketType.fromValue(data.getUint8(0)),
      srcId: data.getUint32(1),
      dstId: data.getUint32(5),
      seqNum: data.getUint16(9),
      hopCount: data.getUint8(11),
      timestampMs: data.getUint64(12),
      keyEpoch: data.getUint32(20),
      nonce: Uint8List.sublistView(bytes, 24, 36),
      authTag: Uint8List.sublistView(bytes, 36, 52),
      payload: Uint8List.sublistView(bytes, headerLength),
    );
  }

  /// Header prefix (type..key_epoch) bound as AES-GCM associated data so a
  /// relay cannot re-attribute, re-order, or re-epoch a voice frame.
  ///
  /// hop_count (offset 11) is zeroed: it is the TTL that relays legitimately
  /// decrement, so it must not participate in authentication.
  Uint8List aadBytes() {
    final aad = Uint8List(aadLength);
    aad.setRange(0, aadLength, encode());
    aad[11] = 0;
    return aad;
  }

  /// Copy with a decremented TTL for forwarding.
  MeshPacket forwarded() {
    return copyWith(hopCount: hopCount - 1);
  }

  MeshPacket copyWith({
    int? hopCount,
    Uint8List? nonce,
    Uint8List? authTag,
    Uint8List? payload,
    int? keyEpoch,
  }) {
    return MeshPacket(
      type: type,
      srcId: srcId,
      dstId: dstId,
      seqNum: seqNum,
      hopCount: hopCount ?? this.hopCount,
      timestampMs: timestampMs,
      keyEpoch: keyEpoch ?? this.keyEpoch,
      nonce: nonce ?? this.nonce,
      authTag: authTag ?? this.authTag,
      payload: payload ?? this.payload,
    );
  }
}

/// Derives a stable 32-bit node ID from a transport-level string ID
/// (FNV-1a). The mesh wire format uses 4-byte IDs per the design doc while
/// transports address peers by UUID strings.
int nodeIdFromString(String id) {
  var hash = 0x811C9DC5;
  for (final unit in id.codeUnits) {
    hash ^= unit & 0xFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  // Reserve the broadcast value.
  return hash == broadcastId ? 0xFFFFFFFE : hash;
}
