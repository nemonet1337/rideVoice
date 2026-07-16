import 'lan_transport.dart';
import 'mesh_transport.dart';

/// Picks the transport for the current connectivity state (design doc §1-2).
///
/// Online → null: audio flows through LiveKit SFU (WebRTC), no mesh
/// transport is needed. Offline → the LAN overlay mesh, which serves both
/// Android and iOS (see docs/DESIGN_DEVIATIONS.md — Nearby Connections /
/// MultipeerConnectivity were descoped in favour of the LAN overlay).
abstract class TransportSelector {
  MeshTransport? select({
    required bool isOnline,
    required String? peerOS,
  });
}

class DefaultTransportSelector implements TransportSelector {
  final MeshTransport Function() _offlineTransportFactory;

  DefaultTransportSelector({
    MeshTransport Function()? offlineTransportFactory,
  }) : _offlineTransportFactory =
            offlineTransportFactory ?? (() => LanTransport());

  @override
  MeshTransport? select({
    required bool isOnline,
    required String? peerOS,
  }) {
    if (isOnline) return null; // LiveKit SFU handles the online path.
    return _offlineTransportFactory();
  }
}
