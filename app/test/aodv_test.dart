import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/mesh/aodv.dart';

import 'support/in_memory_transport.dart';

/// Multi-node AODV simulation over an in-memory LAN segment with explicit
/// topology (design doc §3-3, §6-1, §6-2).
void main() {
  const tick = Duration(milliseconds: 40);

  MeshNode buildNode(
    InMemoryHub hub,
    String id, {
    double battery = 0.4,
    double rssi = 0.5,
    VoicePacketCrypto? crypto,
  }) {
    return MeshNode(
      transport: hub.createTransport(id),
      stats: NodeStats(batteryLevel: battery, rssiStability: rssi),
      heartbeatPeriod: tick,
      discoveryTimeout: const Duration(milliseconds: 400),
      crypto: crypto,
    );
  }

  Future<void> settle([int ms = 150]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Uint8List frame(int filler) => Uint8List.fromList(List.filled(40, filler));

  test('RREQ/RREP establishes a multi-hop route and voice flows over it',
      () async {
    final hub = InMemoryHub();
    final a = buildNode(hub, 'A');
    final b = buildNode(hub, 'B');
    final c = buildNode(hub, 'C');
    hub.link('A', 'B');
    hub.link('B', 'C');

    await a.start();
    await b.start();
    await c.start();
    await settle();

    // A and C are not direct neighbors.
    expect(a.neighbors, isNot(contains(c.localId)));

    final found = await a.discoverRoute(c.localId);
    await pumpEventQueue();
    expect(found, isTrue);
    expect(a.router.nextHop(c.localId), b.localId);

    final received = <VoiceFrame>[];
    c.voiceFrames.listen(received.add);

    await a.sendVoice(frame(7), dstId: c.localId);
    await pumpEventQueue();

    expect(received, hasLength(1));
    expect(received.single.srcId, a.localId);
    expect(received.single.payload, frame(7));
    expect(b.forwardedCount, greaterThan(0));

    await a.stop();
    await b.stop();
    await c.stop();
  });

  test('broadcast voice floods the mesh exactly once per node', () async {
    final hub = InMemoryHub();
    final a = buildNode(hub, 'A');
    final b = buildNode(hub, 'B');
    final c = buildNode(hub, 'C');
    hub.linkAll();

    await a.start();
    await b.start();
    await c.start();
    await settle();

    final atB = <VoiceFrame>[];
    final atC = <VoiceFrame>[];
    b.voiceFrames.listen(atB.add);
    c.voiceFrames.listen(atC.add);

    await a.sendVoice(frame(1));
    await pumpEventQueue();

    // Full mesh means both direct delivery and a relayed copy arrive;
    // dedupe must keep exactly one.
    expect(atB, hasLength(1));
    expect(atC, hasLength(1));

    await a.stop();
    await b.stop();
    await c.stop();
  });

  test('TTL limits propagation to 4 hops (§1-3, §3-4)', () async {
    final hub = InMemoryHub();
    final ids = ['A', 'B', 'C', 'D', 'E', 'F'];
    final nodes = [for (final id in ids) buildNode(hub, id)];
    for (var i = 0; i < ids.length - 1; i++) {
      hub.link(ids[i], ids[i + 1]);
    }
    for (final n in nodes) {
      await n.start();
    }
    await settle();

    final a = nodes.first;
    final e = nodes[4]; // 4 links away — reachable at the TTL edge.
    final f = nodes[5]; // 5 links away — beyond max hops.

    expect(await a.discoverRoute(e.localId), isTrue);
    expect(await a.discoverRoute(f.localId), isFalse);

    // Broadcast voice also stops after 4 links.
    final atE = <VoiceFrame>[];
    final atF = <VoiceFrame>[];
    e.voiceFrames.listen(atE.add);
    f.voiceFrames.listen(atF.add);
    await a.sendVoice(frame(9));
    await pumpEventQueue();
    expect(atE, hasLength(1));
    expect(atF, isEmpty);

    for (final n in nodes) {
      await n.stop();
    }
  });

  test('3 missed heartbeats mark a neighbor dead and trigger RERR (§6-1/2)',
      () async {
    final hub = InMemoryHub();
    final a = buildNode(hub, 'A');
    final b = buildNode(hub, 'B');
    final c = buildNode(hub, 'C');
    hub.link('A', 'B');
    hub.link('B', 'C');

    await a.start();
    await b.start();
    await c.start();
    await settle();

    expect(await a.discoverRoute(c.localId), isTrue);

    final events = <MeshEvent>[];
    a.events.listen(events.add);

    // C dies; B must detect it after 3 missed beats and propagate RERR,
    // invalidating A's route through B.
    await c.stop();
    await settle(400);

    expect(
      events.any((e) =>
          e.type == MeshEventType.routeError && e.nodeId == c.localId),
      isTrue,
      reason: 'A should learn via RERR that C became unreachable',
    );
    expect(a.router.nextHop(c.localId), isNull);

    await a.stop();
    await b.stop();
  });

  test('reroute after next-hop failure (§6-2 迂回経路の自動再探索)', () async {
    final hub = InMemoryHub();
    final a = buildNode(hub, 'A');
    final b = buildNode(hub, 'B');
    final c = buildNode(hub, 'C');
    final d = buildNode(hub, 'D');
    // Diamond: A-B-C and A-D-C.
    hub.link('A', 'B');
    hub.link('B', 'C');
    hub.link('A', 'D');
    hub.link('D', 'C');

    await a.start();
    await b.start();
    await c.start();
    await d.start();
    await settle();

    expect(await a.discoverRoute(c.localId), isTrue);
    final firstHop = a.router.nextHop(c.localId);
    expect(firstHop, isNotNull);

    // Kill whichever relay the route uses.
    final relay = firstHop == b.localId ? b : d;
    final alternate = firstHop == b.localId ? d : b;
    await relay.stop();
    await settle(400);

    expect(a.router.nextHop(c.localId), isNull,
        reason: 'route through the dead relay must be evicted');

    expect(await a.discoverRoute(c.localId), isTrue,
        reason: 'a detour through the surviving relay must be found');
    expect(a.router.nextHop(c.localId), alternate.localId);

    final received = <VoiceFrame>[];
    c.voiceFrames.listen(received.add);
    await a.sendVoice(frame(3), dstId: c.localId);
    await pumpEventQueue();
    expect(received, hasLength(1));

    await a.stop();
    await alternate.stop();
    await c.stop();
  });

  test('ClusterHead death triggers re-election (§6-2, within 2 s)', () async {
    final hub = InMemoryHub();
    // B has the best §3-2 stats and becomes head.
    final a = buildNode(hub, 'A', battery: 0.4, rssi: 0.5);
    final b = buildNode(hub, 'B', battery: 1.0, rssi: 1.0);
    final c = buildNode(hub, 'C', battery: 0.3, rssi: 0.4);
    hub.linkAll();

    await a.start();
    await b.start();
    await c.start();
    await settle(300);

    expect(a.router.electClusterHead(), b.localId);

    final events = <MeshEvent>[];
    a.events.listen(events.add);
    final headDiedAt = DateTime.now();
    await b.stop();

    // 3 missed 40 ms beats + election happens on the detection tick.
    await settle(400);
    final elected = events
        .where((e) => e.type == MeshEventType.headElected)
        .toList();
    expect(elected, isNotEmpty, reason: 'a new head must be elected');
    expect(elected.first.nodeId, isNot(b.localId));
    expect(
      DateTime.now().difference(headDiedAt),
      lessThan(const Duration(seconds: 2)),
      reason: '§6-2: new head within 2 seconds',
    );

    await a.stop();
    await c.stop();
  });

  test('malformed datagrams are dropped without crashing', () async {
    final hub = InMemoryHub();
    final a = buildNode(hub, 'A');
    final b = buildNode(hub, 'B');
    hub.linkAll();

    await a.start();
    await b.start();
    await settle();

    final garbage = Uint8List.fromList(List.filled(10, 0xFF));
    final transportB = b.transport;
    await transportB.send(garbage, 'A');
    await pumpEventQueue();

    // A keeps working afterwards.
    final received = <VoiceFrame>[];
    a.voiceFrames.listen(received.add);
    await b.sendVoice(frame(5));
    await pumpEventQueue();
    expect(received, hasLength(1));

    await a.stop();
    await b.stop();
  });
}
