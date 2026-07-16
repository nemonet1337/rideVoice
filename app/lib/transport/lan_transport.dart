import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'mesh_transport.dart';

/// LAN overlay transport (see AGENTS.md "Cross-OS mesh"): peers on a shared
/// WiFi network / hotspot discover each other with periodic UDP broadcast
/// HELLOs and exchange mesh packets as binary UDP datagrams.
///
/// Wire format:
///  - HELLO datagram: [0x48 'H'] + UTF-8 node ID (broadcast, also sent as a
///    reply so both sides learn each other).
///  - DATA  datagram: [0x44 'D'] + MeshPacket bytes (unicast).
class LanTransport implements MeshTransport {
  static const int _helloMarker = 0x48;
  static const int _dataMarker = 0x44;

  final _log = Logger('LanTransport');
  final int _port;
  final Duration helloInterval;

  final String _localId;
  RawDatagramSocket? _socket;
  Timer? _helloTimer;
  final _messageController = StreamController<MeshMessage>.broadcast();
  final _peers = <String, _PeerAddress>{};
  bool _running = false;

  LanTransport({
    int port = 61420,
    this.helloInterval = const Duration(seconds: 2),
    String? localId,
  })  : _port = port,
        _localId = localId ?? const Uuid().v4();

  @override
  String get localId => _localId;

  @override
  bool get isRunning => _running;

  @override
  Stream<MeshMessage> get messages => _messageController.stream;

  /// Port actually bound (useful when constructed with port 0 in tests).
  int? get boundPort => _socket?.port;

  @override
  Future<void> start() async {
    if (_running) return;

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _port);
    socket.broadcastEnabled = true;
    socket.listen(_onSocketEvent);
    _socket = socket;

    _helloTimer = Timer.periodic(helloInterval, (_) => _sendHello());
    _running = true;
    _sendHello();
    _log.info('LanTransport $_localId started on UDP ${socket.port}');
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _helloTimer?.cancel();
    _socket?.close();
    _socket = null;
    await _messageController.close();
    _log.info('LanTransport stopped');
  }

  @override
  Future<void> send(Uint8List data, String targetId) async {
    final socket = _socket;
    final peer = _peers[targetId];
    if (socket == null || peer == null) {
      _log.warning('peer $targetId not known; dropping ${data.length} bytes');
      return;
    }
    final framed = Uint8List(data.length + 1)
      ..[0] = _dataMarker
      ..setRange(1, data.length + 1, data);
    socket.send(framed, peer.address, peer.port);
  }

  @override
  Future<List<String>> discoverPeers() async {
    _sendHello();
    // Peers answer HELLOs immediately; give them a beat to respond.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    return _peers.keys.toList();
  }

  void _sendHello() {
    final socket = _socket;
    // Port 0 means an ephemeral bind (tests); peers can't be reached by
    // broadcast on a port nobody agreed on, so skip it.
    if (socket == null || _port == 0) return;
    final idBytes = _localId.codeUnits;
    final framed = Uint8List(idBytes.length + 1)
      ..[0] = _helloMarker
      ..setRange(1, idBytes.length + 1, idBytes);
    try {
      socket.send(framed, InternetAddress('255.255.255.255'), _port);
    } catch (e) {
      // Broadcast may be unavailable off-LAN or in sandboxes.
      _log.fine('broadcast HELLO failed: $e');
    }
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    final datagram = socket.receive();
    if (datagram == null || datagram.data.isEmpty) return;

    final marker = datagram.data[0];
    final body = Uint8List.sublistView(datagram.data, 1);

    if (marker == _helloMarker) {
      final peerId = String.fromCharCodes(body);
      if (peerId.isEmpty || peerId == _localId) return;
      final known = _peers.containsKey(peerId);
      _peers[peerId] = _PeerAddress(datagram.address, datagram.port);
      if (!known) {
        // Answer directly so the new peer learns us without waiting for
        // the next broadcast interval.
        final idBytes = _localId.codeUnits;
        final framed = Uint8List(idBytes.length + 1)
          ..[0] = _helloMarker
          ..setRange(1, idBytes.length + 1, idBytes);
        socket.send(framed, datagram.address, datagram.port);
      }
    } else if (marker == _dataMarker) {
      final senderId = _peerIdFor(datagram.address, datagram.port);
      if (senderId == null) {
        _log.fine('data from unknown peer ${datagram.address}');
        return;
      }
      _messageController.add(MeshMessage(senderId: senderId, data: body));
    }
  }

  String? _peerIdFor(InternetAddress address, int port) {
    for (final entry in _peers.entries) {
      if (entry.value.address == address && entry.value.port == port) {
        return entry.key;
      }
    }
    return null;
  }
}

class _PeerAddress {
  final InternetAddress address;
  final int port;

  _PeerAddress(this.address, this.port);
}
