import 'lan_transport.dart';
import 'mesh_transport.dart';

/// Picks the mesh transport. Always a real transport — there is no SFU path.
///
/// LAN overlay serves both Android and iOS (see docs/DESIGN_DEVIATIONS.md).
/// A WebRTC data-channel transport can be composed later without changing
/// callers that already consume [MeshTransport].
abstract class TransportSelector {
  MeshTransport select();
}

class DefaultTransportSelector implements TransportSelector {
  final MeshTransport Function() _transportFactory;

  DefaultTransportSelector({
    MeshTransport Function()? transportFactory,
  }) : _transportFactory = transportFactory ?? (() => LanTransport());

  @override
  MeshTransport select() => _transportFactory();
}
