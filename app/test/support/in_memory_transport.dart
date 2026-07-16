import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:ridevoice/transport/mesh_transport.dart';

/// Test hub simulating a LAN segment: explicit link topology, seeded
/// probabilistic packet loss, and asynchronous delivery so tests exercise
/// real event-loop ordering.
class InMemoryHub {
  final _transports = <String, InMemoryMeshTransport>{};
  final _links = <String>{};
  final Random _random;

  /// Probability that any datagram is silently dropped (communication
  /// quality injection).
  double lossRate;

  int deliveredCount = 0;
  int droppedCount = 0;

  InMemoryHub({this.lossRate = 0.0, int seed = 42}) : _random = Random(seed);

  InMemoryMeshTransport createTransport(String id) {
    final transport = InMemoryMeshTransport._(this, id);
    _transports[id] = transport;
    return transport;
  }

  /// Creates a bidirectional link between two peers.
  void link(String a, String b) {
    _links.add(_linkKey(a, b));
  }

  void unlink(String a, String b) {
    _links.remove(_linkKey(a, b));
  }

  /// Links every registered transport to every other (single WiFi segment).
  void linkAll() {
    final ids = _transports.keys.toList();
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        link(ids[i], ids[j]);
      }
    }
  }

  static String _linkKey(String a, String b) =>
      a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

  bool _linked(String a, String b) => _links.contains(_linkKey(a, b));

  List<String> _peersOf(String id) => _transports.keys
      .where((other) =>
          other != id &&
          _linked(id, other) &&
          (_transports[other]?.isRunning ?? false))
      .toList();

  void _deliver(String from, String to, Uint8List data) {
    if (!_linked(from, to)) return;
    final target = _transports[to];
    if (target == null || !target.isRunning) return;
    if (lossRate > 0 && _random.nextDouble() < lossRate) {
      droppedCount++;
      return;
    }
    deliveredCount++;
    final copy = Uint8List.fromList(data);
    Timer.run(() {
      if (target.isRunning) {
        target._controller.add(MeshMessage(senderId: from, data: copy));
      }
    });
  }
}

class InMemoryMeshTransport implements MeshTransport {
  final InMemoryHub _hub;
  final String _id;
  final _controller = StreamController<MeshMessage>.broadcast();
  bool _running = false;

  InMemoryMeshTransport._(this._hub, this._id);

  @override
  String get localId => _id;

  @override
  bool get isRunning => _running;

  @override
  Stream<MeshMessage> get messages => _controller.stream;

  @override
  Future<void> start() async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _controller.close();
  }

  @override
  Future<void> send(Uint8List data, String targetId) async {
    if (!_running) return;
    _hub._deliver(_id, targetId, data);
  }

  @override
  Future<List<String>> discoverPeers() async => _hub._peersOf(_id);
}
