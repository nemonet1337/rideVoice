import 'dart:math';

const double maxClusterSize = 8;
const double maxHops = 4;
const Duration heartbeatInterval = Duration(seconds: 1);
const double heartbeatTimeout = 3;
const Duration reelectTimeout = Duration(seconds: 2);

class ClusterNode {
  final String id;
  final double batteryLevel;
  final int connectionDegree;
  final double rssiStability;

  ClusterNode({
    required this.id,
    required this.batteryLevel,
    required this.connectionDegree,
    required this.rssiStability,
  });

  double get headScore {
    double batteryScore = batteryLevel > 0.5 ? 1.0 : 0.0;
    double degreeScore = connectionDegree >= 3 ? 1.0 : connectionDegree / 3.0;
    double rssiScore = rssiStability > 0.7 ? 1.0 : rssiStability / 0.7;
    return batteryScore * 0.4 + degreeScore * 0.3 + rssiScore * 0.3;
  }
}

class MeshRouter {
  final String _localId;
  final _routingTable = <String, _RouteEntry>{};
  final _clusterMembers = <String, ClusterNode>{};
  String? _clusterHead;
  String? _gatewayId;

  MeshRouter(this._localId);

  void addNode(ClusterNode node) {
    _clusterMembers[node.id] = node;
  }

  void removeNode(String id) {
    _clusterMembers.remove(id);
  }

  String? electClusterHead() {
    if (_clusterMembers.isEmpty) {
      _clusterHead = null;
      return null;
    }

    double bestScore = -1;
    String? bestId;
    for (final node in _clusterMembers.values) {
      if (node.headScore > bestScore) {
        bestScore = node.headScore;
        bestId = node.id;
      }
    }

    if (bestId != null && _clusterMembers.length <= maxClusterSize) {
      _clusterHead = bestId;
    }
    return _clusterHead;
  }

  String? get clusterHead => _clusterHead;

  bool get isClusterHead =>
      _clusterHead != null && _clusterHead == _localId;

  bool get isGateway => _gatewayId != null;

  void addRoute(String dest, String nextHop, int hopCount) {
    _routingTable[dest] = _RouteEntry(
      nextHop: nextHop,
      hopCount: hopCount,
      lastHeard: DateTime.now(),
    );
  }

  void removeRoute(String dest) {
    _routingTable.remove(dest);
  }

  String? nextHop(String destination) {
    final route = _routingTable[destination];
    if (route == null) return null;
    if (DateTime.now().difference(route.lastHeard).inSeconds > heartbeatTimeout) {
      _routingTable.remove(destination);
      return null;
    }
    return route.nextHop;
  }

  List<String> get reachableNodes => _routingTable.keys.toList();

  void setGateway(String gatewayId) {
    _gatewayId = gatewayId;
  }
}

class _RouteEntry {
  final String nextHop;
  final int hopCount;
  final DateTime lastHeard;

  _RouteEntry({
    required this.nextHop,
    required this.hopCount,
    required this.lastHeard,
  });
}
