import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/transport/lan_transport.dart';
import 'package:ridevoice/transport/transport_selector.dart';

import 'support/in_memory_transport.dart';

void main() {
  test('localId is stable and start() can be called safely', () async {
    // Regression: _localId used to be a `late final` reassigned in start(),
    // crashing the transport on first use.
    final transport = LanTransport(port: 0);
    final idBefore = transport.localId;
    expect(idBefore, isNotEmpty);

    await transport.start();
    expect(transport.localId, idBefore);
    expect(transport.isRunning, isTrue);
    expect(transport.boundPort, isNotNull);

    await transport.stop();
    expect(transport.isRunning, isFalse);
  });

  test('send to an unknown peer is dropped, not crashed', () async {
    final transport = LanTransport(port: 0);
    await transport.start();
    await transport.send(Uint8List.fromList([1, 2, 3]), 'nobody');
    await transport.stop();
  });

  test('DefaultTransportSelector: online → null (LiveKit), offline → mesh',
      () {
    final hub = InMemoryHub();
    final selector = DefaultTransportSelector(
      offlineTransportFactory: () => hub.createTransport('X'),
    );

    expect(
      selector.select(isOnline: true, peerOS: 'android'),
      isNull,
      reason: 'online audio goes through the SFU, no mesh transport',
    );
    expect(
      selector.select(isOnline: false, peerOS: 'android'),
      isNotNull,
    );
    expect(
      selector.select(isOnline: false, peerOS: 'ios'),
      isNotNull,
      reason: 'the LAN overlay serves both platforms',
    );
  });
}
