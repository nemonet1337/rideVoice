import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/signaling/signaling.dart';

void main() {
  test('SignalingClient can be instantiated', () {
    final client = SignalingClient(baseUrl: 'http://localhost:8080');
    expect(client, isNotNull);
    client.dispose();
  });

  test('SignalingException holds message', () {
    final ex = SignalingException('test error');
    expect(ex.message, 'test error');
  });
}
