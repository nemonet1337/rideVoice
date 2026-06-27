import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/mesh/mesh.dart';

void main() {
  group('ClusterNode', () {
    test('head score calculation - ideal node', () {
      final node = ClusterNode(
        id: 'node1',
        batteryLevel: 0.9,
        connectionDegree: 5,
        rssiStability: 0.95,
      );
      expect(node.headScore, closeTo(1.0, 0.01));
    });

    test('head score calculation - poor node', () {
      final node = ClusterNode(
        id: 'node2',
        batteryLevel: 0.1,
        connectionDegree: 0,
        rssiStability: 0.1,
      );
      expect(node.headScore, lessThan(0.2));
    });
  });

  group('MeshRouter', () {
    test('electClusterHead with single node', () {
      final router = MeshRouter('local');
      router.addNode(ClusterNode(
        id: 'local',
        batteryLevel: 0.8,
        connectionDegree: 0,
        rssiStability: 1.0,
      ));
      final head = router.electClusterHead();
      expect(head, isNotNull);
    });

    test('electClusterHead picks highest score', () {
      final router = MeshRouter('local');
      router.addNode(ClusterNode(
        id: 'local',
        batteryLevel: 0.3,
        connectionDegree: 1,
        rssiStability: 0.5,
      ));
      router.addNode(ClusterNode(
        id: 'remote',
        batteryLevel: 0.9,
        connectionDegree: 5,
        rssiStability: 0.9,
      ));
      final head = router.electClusterHead();
      expect(head, equals('remote'));
    });

    test('route table operations', () {
      final router = MeshRouter('local');
      router.addRoute('dest', 'nextHop', 1);
      expect(router.nextHop('dest'), equals('nextHop'));
      expect(router.reachableNodes, contains('dest'));

      router.removeRoute('dest');
      expect(router.nextHop('dest'), isNull);
    });
  });
}
