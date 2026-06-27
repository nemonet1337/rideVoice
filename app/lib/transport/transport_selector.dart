import 'mesh_transport.dart';

abstract class TransportSelector {
  MeshTransport? select({
    required bool isOnline,
    required String? peerOS,
  });
}

class DefaultTransportSelector implements TransportSelector {
  @override
  MeshTransport? select({
    required bool isOnline,
    required String? peerOS,
  }) {
    if (isOnline) return null;
    if (peerOS == null) return null;

    return switch (peerOS.toLowerCase()) {
      'android' || 'ios' => null,
      _ => null,
    };
  }
}
