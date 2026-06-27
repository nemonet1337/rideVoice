import 'dart:typed_data';

abstract class MeshTransport {
  Future<void> start();
  Future<void> stop();
  Future<void> send(Uint8List data, String targetId);
  Stream<MeshMessage> get messages;
  Future<List<String>> discoverPeers();
  String get localId;
  bool get isRunning;
}

class MeshMessage {
  final String senderId;
  final Uint8List data;
  final DateTime timestamp;

  MeshMessage({
    required this.senderId,
    required this.data,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

enum TransportType {
  lan,
  nearbyConnections,
  multipeer,
}
