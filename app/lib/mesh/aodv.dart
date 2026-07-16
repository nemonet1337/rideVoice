import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:logging/logging.dart';

import '../transport/mesh_transport.dart';
import 'mesh.dart';
import 'packet.dart';

/// Result of sealing a voice payload (nonce and tag travel in the packet
/// header per design doc §3-4).
class SealedVoice {
  final Uint8List nonce;
  final Uint8List authTag;
  final Uint8List ciphertext;

  SealedVoice({
    required this.nonce,
    required this.authTag,
    required this.ciphertext,
  });
}

/// Encryption hook for voice packets. Implemented by the crypto layer
/// (GroupVoiceCrypto); kept abstract here so the mesh can be tested
/// without keys.
abstract class VoicePacketCrypto {
  /// Epoch of the group key that will be used for the next seal.
  int get currentEpoch;

  /// Seals [plaintext] binding [aad] (the packet header prefix).
  Future<SealedVoice> seal(Uint8List plaintext, Uint8List aad);

  /// Opens a received voice packet; returns null when authentication
  /// fails (tampered, replayed under wrong header, or unknown epoch).
  Future<Uint8List?> open(MeshPacket packet);
}

/// Local link-quality statistics advertised in heartbeats and used for
/// ClusterHead election (design doc §3-2).
class NodeStats {
  double batteryLevel;
  double rssiStability;

  NodeStats({this.batteryLevel = 1.0, this.rssiStability = 1.0});
}

class VoiceFrame {
  final int srcId;
  final int seqNum;
  final int timestampMs;
  final Uint8List payload;

  VoiceFrame({
    required this.srcId,
    required this.seqNum,
    required this.timestampMs,
    required this.payload,
  });
}

enum MeshEventType { neighborLost, routeError, headElected }

class MeshEvent {
  final MeshEventType type;
  final int nodeId;

  MeshEvent(this.type, this.nodeId);
}

/// Connects a [MeshTransport] to the AODV routing layer (design doc §3-3):
/// route discovery (RREQ/RREP), failure propagation (RERR), heartbeats with
/// 3-miss dead detection (§6-1), TTL-bounded relaying, and optional voice
/// encryption via [VoicePacketCrypto].
class MeshNode {
  final _log = Logger('MeshNode');

  final MeshTransport transport;
  final VoicePacketCrypto? crypto;
  final NodeStats stats;
  final Duration heartbeatPeriod;
  final int missLimit;
  final Duration discoveryTimeout;

  late final int localId;
  late final MeshRouter router;

  final _neighborAddresses = <int, String>{};
  final _neighborLastSeen = <int, DateTime>{};
  final _seenVoice = LinkedHashSet<int>();
  final _seenRequests = LinkedHashSet<int>();
  final _pendingDiscoveries = <int, Completer<bool>>{};
  final _voiceController = StreamController<VoiceFrame>.broadcast();
  final _eventController = StreamController<MeshEvent>.broadcast();

  StreamSubscription<MeshMessage>? _rxSub;
  Timer? _heartbeatTimer;
  int _seqNum = 0;
  int _requestId = 0;
  bool _running = false;

  /// Communication-quality counters.
  int authFailureCount = 0;
  int forwardedCount = 0;
  int droppedNoRoute = 0;
  int droppedTtlExceeded = 0;

  static const int _dedupeCacheLimit = 4096;

  MeshNode({
    required this.transport,
    this.crypto,
    NodeStats? stats,
    this.heartbeatPeriod = heartbeatInterval,
    this.missLimit = heartbeatMissLimit,
    this.discoveryTimeout = const Duration(seconds: 3),
  }) : stats = stats ?? NodeStats();

  Stream<VoiceFrame> get voiceFrames => _voiceController.stream;
  Stream<MeshEvent> get events => _eventController.stream;
  bool get isRunning => _running;
  List<int> get neighbors => _neighborAddresses.keys.toList();

  Future<void> start() async {
    if (_running) return;
    if (!transport.isRunning) {
      await transport.start();
    }
    localId = nodeIdFromString(transport.localId);
    router = MeshRouter(localId);
    router.addNode(_localClusterNode());

    _rxSub = transport.messages.listen(_onMessage);
    _heartbeatTimer = Timer.periodic(heartbeatPeriod, (_) => _onHeartbeatTick());
    _running = true;

    // Bootstrap: greet any peers the transport can already see.
    final peers = await transport.discoverPeers();
    for (final peer in peers) {
      _neighborAddresses[nodeIdFromString(peer)] = peer;
    }
    await _sendHeartbeat();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _heartbeatTimer?.cancel();
    await _rxSub?.cancel();
    for (final completer in _pendingDiscoveries.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _pendingDiscoveries.clear();
    await _voiceController.close();
    await _eventController.close();
  }

  ClusterNode _localClusterNode() => ClusterNode(
        id: localId,
        batteryLevel: stats.batteryLevel,
        connectionDegree: _neighborAddresses.length,
        rssiStability: stats.rssiStability,
      );

  int _nextSeq() {
    _seqNum = (_seqNum + 1) & 0xFFFF;
    return _seqNum;
  }

  // ---------------------------------------------------------------------
  // Sending
  // ---------------------------------------------------------------------

  /// Sends a voice frame to the whole group (default) or a single node.
  Future<void> sendVoice(Uint8List payload, {int dstId = broadcastId}) async {
    if (!_running) return;
    final draft = MeshPacket(
      type: PacketType.voice,
      srcId: localId,
      dstId: dstId,
      seqNum: _nextSeq(),
      hopCount: maxHops,
      timestampMs: clock.now().millisecondsSinceEpoch,
      keyEpoch: crypto?.currentEpoch ?? 0,
      payload: payload,
    );

    MeshPacket packet = draft;
    if (crypto != null) {
      final sealed = await crypto!.seal(payload, draft.aadBytes());
      packet = draft.copyWith(
        nonce: sealed.nonce,
        authTag: sealed.authTag,
        payload: sealed.ciphertext,
      );
    }
    _rememberVoice(packet.srcId, packet.seqNum);

    if (dstId == broadcastId) {
      await _broadcast(packet);
    } else {
      await _sendTowards(packet);
    }
  }

  /// AODV route discovery (§3-3). Completes true once a ROUTE_REPLY
  /// arrives, false on timeout.
  Future<bool> discoverRoute(int targetId) {
    if (router.nextHop(targetId) != null) {
      return Future.value(true);
    }
    final pending = _pendingDiscoveries[targetId];
    if (pending != null) return pending.future;

    final completer = Completer<bool>();
    _pendingDiscoveries[targetId] = completer;

    _requestId = (_requestId + 1) & 0xFFFFFFFF;
    final payload = ByteData(12)
      ..setUint32(0, localId)
      ..setUint32(4, targetId)
      ..setUint32(8, _requestId);
    final packet = MeshPacket(
      type: PacketType.routeRequest,
      srcId: localId,
      dstId: broadcastId,
      seqNum: _nextSeq(),
      hopCount: maxHops,
      timestampMs: clock.now().millisecondsSinceEpoch,
      payload: payload.buffer.asUint8List(),
    );
    _rememberRequest(localId, _requestId);
    _broadcast(packet);

    Timer(discoveryTimeout, () {
      final c = _pendingDiscoveries.remove(targetId);
      if (c != null && !c.isCompleted) c.complete(false);
    });
    return completer.future;
  }

  Future<void> _broadcast(MeshPacket packet, {int? excludeNeighbor}) async {
    final data = packet.encode();
    for (final entry in _neighborAddresses.entries) {
      if (entry.key == excludeNeighbor) continue;
      try {
        await transport.send(data, entry.value);
      } catch (e) {
        _log.warning('broadcast to ${entry.key} failed: $e');
      }
    }
  }

  Future<void> _sendTowards(MeshPacket packet) async {
    final next = router.nextHop(packet.dstId);
    if (next == null) {
      droppedNoRoute++;
      // Kick off discovery so subsequent frames can flow (§6-2 re-search).
      unawaited(discoverRoute(packet.dstId));
      return;
    }
    final address = _neighborAddresses[next];
    if (address == null) {
      droppedNoRoute++;
      return;
    }
    await transport.send(packet.encode(), address);
    // Active routes stay fresh while traffic flows.
    router.refreshRoute(packet.dstId);
  }

  // ---------------------------------------------------------------------
  // Receiving
  // ---------------------------------------------------------------------

  Future<void> _onMessage(MeshMessage message) async {
    final MeshPacket packet;
    try {
      packet = MeshPacket.decode(message.data);
    } on FormatException catch (e) {
      _log.warning('undecodable packet from ${message.senderId}: $e');
      return;
    }

    final neighborId = nodeIdFromString(message.senderId);
    _neighborAddresses[neighborId] = message.senderId;
    _neighborLastSeen[neighborId] = clock.now();
    router.addRoute(neighborId, neighborId, 1);

    switch (packet.type) {
      case PacketType.heartbeat:
        _onHeartbeat(packet, neighborId);
      case PacketType.voice:
        await _onVoice(packet, neighborId);
      case PacketType.routeRequest:
        await _onRouteRequest(packet, neighborId);
      case PacketType.routeReply:
        await _onRouteReply(packet, neighborId);
      case PacketType.routeError:
        await _onRouteError(packet, neighborId);
      case PacketType.rekey:
        // Group-key distribution is handled by the group layer; the mesh
        // only relays. Unicast rekey packets follow normal forwarding.
        if (packet.dstId != localId && !packet.isBroadcast) {
          await _forward(packet);
        }
    }
  }

  void _onHeartbeat(MeshPacket packet, int neighborId) {
    if (packet.payload.length >= 3) {
      router.addNode(ClusterNode(
        id: packet.srcId,
        batteryLevel: packet.payload[0] / 100.0,
        connectionDegree: packet.payload[1],
        rssiStability: packet.payload[2] / 255.0,
      ));
    }
  }

  Future<void> _onVoice(MeshPacket packet, int neighborId) async {
    final key = (packet.srcId << 16) | packet.seqNum;
    if (packet.srcId == localId || _seenVoice.contains(key)) {
      return; // Own echo or already relayed.
    }
    _rememberVoice(packet.srcId, packet.seqNum);

    final forMe = packet.dstId == localId || packet.isBroadcast;
    if (forMe) {
      Uint8List? payload = packet.payload;
      if (crypto != null) {
        payload = await crypto!.open(packet);
        if (payload == null) {
          authFailureCount++;
          _log.warning(
              'dropping voice packet from ${packet.srcId}: auth failed');
          return;
        }
      }
      _voiceController.add(VoiceFrame(
        srcId: packet.srcId,
        seqNum: packet.seqNum,
        timestampMs: packet.timestampMs,
        payload: payload,
      ));
    }

    // Relay (§3-1): broadcasts flood with TTL, unicasts follow routes.
    if (packet.isBroadcast) {
      if (packet.hopCount > 1) {
        forwardedCount++;
        await _broadcast(packet.forwarded(), excludeNeighbor: neighborId);
      } else {
        droppedTtlExceeded++;
      }
    } else if (!forMe) {
      await _forward(packet);
    }
  }

  Future<void> _forward(MeshPacket packet) async {
    if (packet.hopCount <= 1) {
      droppedTtlExceeded++;
      return;
    }
    forwardedCount++;
    await _sendTowards(packet.forwarded());
  }

  Future<void> _onRouteRequest(MeshPacket packet, int neighborId) async {
    if (packet.payload.length < 12) return;
    final data = ByteData.sublistView(packet.payload);
    final originId = data.getUint32(0);
    final targetId = data.getUint32(4);
    final requestId = data.getUint32(8);

    if (originId == localId || _seenRequest(originId, requestId)) return;
    _rememberRequest(originId, requestId);

    // Learn the reverse route to the origin through the sender.
    final hopsTraveled = maxHops - packet.hopCount + 1;
    router.addRoute(originId, neighborId, hopsTraveled);

    if (targetId == localId) {
      final reply = MeshPacket(
        type: PacketType.routeReply,
        srcId: localId,
        dstId: originId,
        seqNum: _nextSeq(),
        hopCount: maxHops,
        timestampMs: clock.now().millisecondsSinceEpoch,
        payload: (ByteData(8)
              ..setUint32(0, originId)
              ..setUint32(4, targetId))
            .buffer
            .asUint8List(),
      );
      await _sendTowards(reply);
    } else if (packet.hopCount > 1) {
      await _broadcast(packet.forwarded(), excludeNeighbor: neighborId);
    }
  }

  Future<void> _onRouteReply(MeshPacket packet, int neighborId) async {
    if (packet.payload.length < 8) return;
    final data = ByteData.sublistView(packet.payload);
    final originId = data.getUint32(0);
    final targetId = data.getUint32(4);

    // Learn the forward route to the target through the sender.
    final hopsTraveled = maxHops - packet.hopCount + 1;
    router.addRoute(targetId, neighborId, hopsTraveled);

    if (originId == localId) {
      final completer = _pendingDiscoveries.remove(targetId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(true);
      }
      return;
    }
    await _forward(packet);
  }

  Future<void> _onRouteError(MeshPacket packet, int neighborId) async {
    if (packet.payload.isEmpty) return;
    final data = ByteData.sublistView(packet.payload);
    final count = data.getUint8(0);
    if (packet.payload.length < 1 + count * 4) return;

    final invalidated = <int>[];
    for (var i = 0; i < count; i++) {
      final dest = data.getUint32(1 + i * 4);
      if (router.nextHop(dest) == neighborId) {
        router.removeRoute(dest);
        invalidated.add(dest);
        _eventController.add(MeshEvent(MeshEventType.routeError, dest));
      }
    }
    if (invalidated.isNotEmpty && packet.hopCount > 1) {
      await _broadcast(
        _routeErrorPacket(invalidated, ttl: packet.hopCount - 1),
        excludeNeighbor: neighborId,
      );
    }
  }

  // ---------------------------------------------------------------------
  // Heartbeats & failure detection (§6-1, §6-2)
  // ---------------------------------------------------------------------

  Future<void> _onHeartbeatTick() async {
    await _sendHeartbeat();
    _detectDeadNeighbors();
  }

  Future<void> _sendHeartbeat() async {
    router.addNode(_localClusterNode());
    final payload = Uint8List(3);
    payload[0] = (stats.batteryLevel * 100).round().clamp(0, 100);
    payload[1] = _neighborAddresses.length.clamp(0, 255);
    payload[2] = (stats.rssiStability * 255).round().clamp(0, 255);
    final packet = MeshPacket(
      type: PacketType.heartbeat,
      srcId: localId,
      dstId: broadcastId,
      seqNum: _nextSeq(),
      hopCount: 1, // Heartbeats are link-local.
      timestampMs: clock.now().millisecondsSinceEpoch,
      payload: payload,
    );
    await _broadcast(packet);
  }

  void _detectDeadNeighbors() {
    final now = clock.now();
    final deadline = heartbeatPeriod * missLimit;
    final dead = <int>[];
    _neighborLastSeen.forEach((id, lastSeen) {
      if (now.difference(lastSeen) > deadline) {
        dead.add(id);
      }
    });
    for (final id in dead) {
      _onNeighborDead(id);
    }
  }

  void _onNeighborDead(int neighborId) {
    _log.info('neighbor $neighborId timed out ($missLimit missed beats)');
    _neighborAddresses.remove(neighborId);
    _neighborLastSeen.remove(neighborId);

    final wasHead = router.clusterHead == neighborId;
    router.removeNode(neighborId);
    final lost = router.removeRoutesVia(neighborId);
    router.removeRoute(neighborId);
    if (!lost.contains(neighborId)) lost.add(neighborId);

    _eventController.add(MeshEvent(MeshEventType.neighborLost, neighborId));
    _broadcast(_routeErrorPacket(lost, ttl: maxHops));

    if (wasHead) {
      // §6-2: new head確定 within 2 s — elect immediately.
      final newHead = router.electClusterHead();
      if (newHead != null) {
        _eventController.add(MeshEvent(MeshEventType.headElected, newHead));
      }
    }
  }

  MeshPacket _routeErrorPacket(List<int> lostDests, {required int ttl}) {
    final count = lostDests.length.clamp(0, 255);
    final payload = ByteData(1 + count * 4);
    payload.setUint8(0, count);
    for (var i = 0; i < count; i++) {
      payload.setUint32(1 + i * 4, lostDests[i]);
    }
    return MeshPacket(
      type: PacketType.routeError,
      srcId: localId,
      dstId: broadcastId,
      seqNum: _nextSeq(),
      hopCount: ttl,
      timestampMs: clock.now().millisecondsSinceEpoch,
      payload: payload.buffer.asUint8List(),
    );
  }

  // ---------------------------------------------------------------------
  // Dedupe caches
  // ---------------------------------------------------------------------

  void _rememberVoice(int srcId, int seqNum) {
    _seenVoice.add((srcId << 16) | seqNum);
    if (_seenVoice.length > _dedupeCacheLimit) {
      _seenVoice.remove(_seenVoice.first);
    }
  }

  bool _seenRequest(int originId, int requestId) =>
      _seenRequests.contains(originId ^ (requestId * 0x9E3779B1));

  void _rememberRequest(int originId, int requestId) {
    _seenRequests.add(originId ^ (requestId * 0x9E3779B1));
    if (_seenRequests.length > _dedupeCacheLimit) {
      _seenRequests.remove(_seenRequests.first);
    }
  }
}
