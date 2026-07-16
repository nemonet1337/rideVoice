import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/mesh/mesh.dart';

void main() {
  group('ClusterNode', () {
    test('head score calculation - ideal node', () {
      final node = ClusterNode(
        id: 1,
        batteryLevel: 0.9,
        connectionDegree: 5,
        rssiStability: 0.95,
      );
      expect(node.headScore, closeTo(1.0, 0.01));
    });

    test('head score calculation - poor node', () {
      final node = ClusterNode(
        id: 2,
        batteryLevel: 0.1,
        connectionDegree: 0,
        rssiStability: 0.1,
      );
      expect(node.headScore, lessThan(0.2));
    });

    test('§3-2 thresholds: battery below 50% zeroes the battery term', () {
      final lowBattery = ClusterNode(
        id: 3,
        batteryLevel: 0.49,
        connectionDegree: 5,
        rssiStability: 1.0,
      );
      final okBattery = ClusterNode(
        id: 4,
        batteryLevel: 0.51,
        connectionDegree: 5,
        rssiStability: 1.0,
      );
      expect(okBattery.headScore - lowBattery.headScore, closeTo(0.4, 0.001));
    });
  });

  group('MeshRouter', () {
    test('electClusterHead with single node', () {
      final router = MeshRouter(100);
      router.addNode(ClusterNode(
        id: 100,
        batteryLevel: 0.8,
        connectionDegree: 0,
        rssiStability: 1.0,
      ));
      expect(router.electClusterHead(), isNotNull);
      expect(router.isClusterHead, isTrue);
    });

    test('electClusterHead picks highest score', () {
      final router = MeshRouter(100);
      router.addNode(ClusterNode(
        id: 100,
        batteryLevel: 0.3,
        connectionDegree: 1,
        rssiStability: 0.5,
      ));
      router.addNode(ClusterNode(
        id: 200,
        batteryLevel: 0.9,
        connectionDegree: 5,
        rssiStability: 0.9,
      ));
      expect(router.electClusterHead(), 200);
      expect(router.isClusterHead, isFalse);
    });

    test('removing the head clears it until re-election', () {
      final router = MeshRouter(100);
      router.addNode(ClusterNode(
        id: 200,
        batteryLevel: 0.9,
        connectionDegree: 5,
        rssiStability: 0.9,
      ));
      router.addNode(ClusterNode(
        id: 100,
        batteryLevel: 0.6,
        connectionDegree: 3,
        rssiStability: 0.8,
      ));
      expect(router.electClusterHead(), 200);

      router.removeNode(200);
      expect(router.clusterHead, isNull);
      expect(router.electClusterHead(), 100);
    });

    test('cluster capacity is 8 (§3-1)', () {
      final router = MeshRouter(0);
      for (var i = 0; i < maxClusterSize; i++) {
        router.addNode(ClusterNode(
          id: i,
          batteryLevel: 1,
          connectionDegree: 3,
          rssiStability: 1,
        ));
      }
      expect(router.isClusterFull, isTrue);
      expect(maxClusterSize, 8);
    });

    test('route table operations', () {
      final router = MeshRouter(100);
      router.addRoute(300, 200, 1);
      expect(router.nextHop(300), 200);
      expect(router.reachableNodes, contains(300));

      router.removeRoute(300);
      expect(router.nextHop(300), isNull);
    });

    test('keeps a fresher shorter route over a longer one', () {
      final router = MeshRouter(100);
      router.addRoute(300, 200, 1);
      router.addRoute(300, 999, 3);
      expect(router.nextHop(300), 200);
    });

    test('removeRoutesVia reports the destinations lost (§6-2)', () {
      final router = MeshRouter(100);
      router.addRoute(300, 200, 2);
      router.addRoute(400, 200, 3);
      router.addRoute(500, 999, 1);

      final lost = router.removeRoutesVia(200);
      expect(lost.toSet(), {300, 400});
      expect(router.nextHop(300), isNull);
      expect(router.nextHop(500), 999);
    });
  });
}
