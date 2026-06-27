import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:multicast_dns/multicast_dns.dart';
import 'package:uuid/uuid.dart';
import 'package:logging/logging.dart';

import 'mesh_transport.dart';

class LanTransport implements MeshTransport {
  final _log = Logger('LanTransport');
  final _uuid = const Uuid();
  final int _tcpPort;
  final int _udpPort;
  final String _serviceName;

  late final String _localId;
  HttpServer? _tcpServer;
  RawDatagramSocket? _udpSocket;
  MDnsClient? _mdnsClient;
  final _messageController = StreamController<MeshMessage>.broadcast();
  final _peers = <String, InternetAddress>{};
  bool _running = false;

  LanTransport({
    int tcpPort = 61420,
    int udpPort = 61421,
    String serviceName = '_ridevoice._tcp',
  })  : _tcpPort = tcpPort,
        _udpPort = udpPort,
        _serviceName = serviceName,
        _localId = '';

  @override
  String get localId => _localId;

  @override
  bool get isRunning => _running;

  @override
  Stream<MeshMessage> get messages => _messageController.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    _localId = _uuid.v4();

    _tcpServer = await HttpServer.bind(InternetAddress.anyIPv4, _tcpPort);
    _tcpServer!.listen(_handleTcpRequest);

    _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, _udpPort);
    _udpSocket!.listen(_handleUdpDatagram);

    _mdnsClient = MDnsClient();
    await _mdnsClient!.start();

    await _advertiseService();
    _running = true;
    _log.info('LanTransport started on TCP:$_tcpPort UDP:$_udpPort');
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _tcpServer?.close(force: true);
    _udpSocket?.close();
    _mdnsClient?.stop();
    _messageController.close();
    _log.info('LanTransport stopped');
  }

  @override
  Future<void> send(Uint8List data, String targetId) async {
    final address = _peers[targetId];
    if (address == null) {
      _log.warning('Peer $targetId not found');
      return;
    }
    final packet = Uint8List.fromList(
      utf8.encode(jsonEncode({
        'src': _localId,
        'dst': targetId,
        'payload': base64Encode(data),
      })),
    );
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.send(packet, address, _udpPort);
    socket.close();
  }

  @override
  Future<List<String>> discoverPeers() async {
    if (_mdnsClient == null) return [];
    final ptr = PtrResourceLookup(serviceType: _serviceName);
    final results = await _mdnsClient!.lookup<PtrResourceRecord>(ptr);
    final peers = <String>[];
    for (final ptrRecord in results) {
      final srv = await _mdnsClient!.lookup<SrvResourceRecord>(
        SrvResourceLookup(service: ptrRecord.domainName),
      );
      for (final srvRecord in srv) {
        final ips = await _mdnsClient!.lookup<IPAddressResourceRecord>(
          IPAddressResourceLookup(domainName: srvRecord.target),
        );
        for (final ip in ips) {
          if (ip.address.address != _localId) {
            peers.add(ip.address.address);
          }
        }
      }
    }
    return peers;
  }

  Future<void> _advertiseService() async {
    if (_mdnsClient == null) return;
    final hostName = InternetAddress.anyIPv4.host;
    await _mdnsClient!.registerService(
      MDnsService(
        name: _localId,
        type: _serviceName,
        port: _tcpPort,
        host: hostName,
        properties: {'version': '0.1.0', 'platform': Platform.operatingSystem},
      ),
    );
  }

  void _handleTcpRequest(HttpRequest request) {
    request
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      try {
        final msg = jsonDecode(line) as Map<String, dynamic>;
        _messageController.add(MeshMessage(
          senderId: msg['src'] as String,
          data: base64Decode(msg['payload'] as String),
        ));
      } catch (e) {
        _log.warning('Failed to parse TCP message: $e');
      }
    });
    request.response.statusCode = 200;
    request.response.close();
  }

  void _handleUdpDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = _udpSocket!.receive();
    if (datagram == null) return;
    try {
      final text = utf8.decode(datagram.data);
      final msg = jsonDecode(text) as Map<String, dynamic>;
      _messageController.add(MeshMessage(
        senderId: msg['src'] as String,
        data: base64Decode(msg['payload'] as String),
      ));
    } catch (e) {
      _log.warning('Failed to parse UDP message: $e');
    }
  }
}
