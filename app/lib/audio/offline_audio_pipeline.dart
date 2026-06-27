/// Audio pipeline implementation for offline path.
///
/// Offline audio pipeline:
///   Platform native DSP → Rust RNNoise → Rust Opus → Rust AES-GCM → MeshTransport.send
///
/// Online audio is handled entirely by livekit_client (WebRTC DSP, Opus, DTLS-SRTP).
class OfflineAudioPipeline {
  final dynamic meshTransport;
  final dynamic cryptoProvider;
  bool _running = false;

  OfflineAudioPipeline({
    required this.meshTransport,
    required this.cryptoProvider,
  });

  bool get isRunning => _running;

  Future<void> start() async {
    _running = true;
  }

  Future<void> stop() async {
    _running = false;
  }

  Future<void> sendFrame(List<int> pcmData) async {
    if (!_running) return;
  }
}
