import 'package:clock/clock.dart';

/// Cluster constraints (design doc §3-1).
const int maxClusterSize = 8;
const int maxHops = 4;

/// Failure detection (design doc §6-1): 1 s heartbeats, dead after
/// 3 consecutive misses, head re-election within 2 s.
const Duration heartbeatInterval = Duration(seconds: 1);
const int heartbeatMissLimit = 3;
const Duration reelectTimeout = Duration(seconds: 2);

class ClusterNode {
  final int id;
  final double batteryLevel;
  final int connectionDegree;
  final double rssiStability;

  ClusterNode({
    required this.id,
    required this.batteryLevel,
    required this.connectionDegree,
    required this.rssiStability,
  });

  /// ClusterHead eligibility score (design doc §3-2): battery > 50%,
  /// connection degree >= 3, signal stability > 0.7.
  double get headScore {
    double batteryScore = batteryLevel > 0.5 ? 1.0 : 0.0;
    double degreeScore = connectionDegree >= 3 ? 1.0 : connectionDegree / 3.0;
    double rssiScore = rssiStability > 0.7 ? 1.0 : rssiStability / 0.7;
    return batteryScore * 0.4 + degreeScore * 0.3 + rssiScore * 0.3;
  }
}

class MeshRouter {
  final int _localId;
  final _routingTable = <int, _RouteEntry>{};
  final _clusterMembers = <int, ClusterNode>{};
  int? _clusterHead;
  int? _gatewayId;

  /// Routes not refreshed within 3 missed heartbeats are stale (§6-1).
  static const Duration routeTtl =
      Duration(seconds: 1 * heartbeatMissLimit);

  MeshRouter(this._localId);

  int get localId => _localId;

  void addNode(ClusterNode node) {
    _clusterMembers[node.id] = node;
  }

  void removeNode(int id) {
    _clusterMembers.remove(id);
    if (_clusterHead == id) {
      _clusterHead = null;
    }
  }

  int get memberCount => _clusterMembers.length;

  bool get isClusterFull => _clusterMembers.length >= maxClusterSize;

  int? electClusterHead() {
    if (_clusterMembers.isEmpty) {
      _clusterHead = null;
      return null;
    }

    double bestScore = -1;
    int? bestId;
    for (final node in _clusterMembers.values) {
      if (node.headScore > bestScore) {
        bestScore = node.headScore;
        bestId = node.id;
      }
    }

    _clusterHead = bestId;
    return _clusterHead;
  }

  int? get clusterHead => _clusterHead;

  bool get isClusterHead => _clusterHead != null && _clusterHead == _localId;

  bool get isGateway => _gatewayId != null && _gatewayId == _localId;

  void addRoute(int dest, int nextHop, int hopCount) {
    final existing = _routingTable[dest];
    // Keep an existing fresher-and-shorter route.
    if (existing != null &&
        existing.hopCount < hopCount &&
        !_isStale(existing)) {
      return;
    }
    _routingTable[dest] = _RouteEntry(
      nextHop: nextHop,
      hopCount: hopCount,
      lastHeard: clock.now(),
    );
  }

  void refreshRoute(int dest) {
    final route = _routingTable[dest];
    if (route != null) {
      _routingTable[dest] = _RouteEntry(
        nextHop: route.nextHop,
        hopCount: route.hopCount,
        lastHeard: clock.now(),
      );
    }
  }

  void removeRoute(int dest) {
    _routingTable.remove(dest);
  }

  /// Removes every route through [neighbor]; returns the destinations that
  /// became unreachable (for ROUTE_ERROR propagation, §6-2).
  List<int> removeRoutesVia(int neighbor) {
    final lost = <int>[];
    _routingTable.removeWhere((dest, route) {
      if (route.nextHop == neighbor) {
        lost.add(dest);
        return true;
      }
      return false;
    });
    return lost;
  }

  bool _isStale(_RouteEntry route) =>
      clock.now().difference(route.lastHeard) > routeTtl;

  int? nextHop(int destination) {
    final route = _routingTable[destination];
    if (route == null) return null;
    if (_isStale(route)) {
      _routingTable.remove(destination);
      return null;
    }
    return route.nextHop;
  }

  int? hopCountTo(int destination) => _routingTable[destination]?.hopCount;

  List<int> get reachableNodes => _routingTable.keys.toList();

  void setGateway(int gatewayId) {
    _gatewayId = gatewayId;
  }
}

class _RouteEntry {
  final int nextHop;
  final int hopCount;
  final DateTime lastHeard;

  _RouteEntry({
    required this.nextHop,
    required this.hopCount,
    required this.lastHeard,
  });
}
