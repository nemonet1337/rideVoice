import 'dart:async';
import 'dart:typed_data';

import '../mesh/aodv.dart';
import 'jitter_buffer.dart';

/// Voice-frame codec stage of the offline pipeline (design doc §2-1).
///
/// The production implementation calls the Rust rv-audio Opus codec over
/// FFI; until that bridge is wired the pipeline runs with
/// [PassthroughFrameCodec] (raw PCM) so the transport/crypto path stays
/// exercised end-to-end.
abstract class FrameCodec {
  Uint8List encode(Uint8List pcm);
  Uint8List decode(Uint8List packet);
}

class PassthroughFrameCodec implements FrameCodec {
  @override
  Uint8List encode(Uint8List pcm) => pcm;

  @override
  Uint8List decode(Uint8List packet) => packet;
}

/// Decoded frame delivered to the playback layer.
class ReceivedAudioFrame {
  final int srcId;
  final Uint8List pcm;

  ReceivedAudioFrame({required this.srcId, required this.pcm});
}

/// Offline audio path (design doc §2-1):
///
///   capture PCM → [FrameCodec.encode] → MeshNode.sendVoice
///     (AES-256-GCM seal + AODV routing happen inside the node)
///   MeshNode.voiceFrames → per-sender [JitterBuffer] reorder
///     → [FrameCodec.decode] → playback.
class OfflineAudioPipeline {
  final MeshNode node;
  final FrameCodec codec;
  final int jitterCapacity;

  final _received = StreamController<ReceivedAudioFrame>.broadcast();
  final _buffers = <int, JitterBuffer>{};
  StreamSubscription<VoiceFrame>? _sub;
  bool _running = false;

  OfflineAudioPipeline({
    required this.node,
    FrameCodec? codec,
    this.jitterCapacity = 4,
  }) : codec = codec ?? PassthroughFrameCodec();

  bool get isRunning => _running;
  Stream<ReceivedAudioFrame> get receivedFrames => _received.stream;

  /// Frames declared lost across all senders (feeds the §6-3 PLC stage).
  int get lostFrameCount =>
      _buffers.values.fold(0, (sum, b) => sum + b.lostFrames);
  int get duplicateFrameCount =>
      _buffers.values.fold(0, (sum, b) => sum + b.duplicateFrames);

  Future<void> start() async {
    if (_running) return;
    if (!node.isRunning) {
      await node.start();
    }
    _sub = node.voiceFrames.listen(_onVoiceFrame);
    _running = true;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _sub?.cancel();
    await _received.close();
  }

  /// Sends one captured PCM frame to the group.
  Future<void> sendFrame(Uint8List pcmData) async {
    if (!_running) return;
    await node.sendVoice(codec.encode(pcmData));
  }

  void _onVoiceFrame(VoiceFrame frame) {
    final buffer =
        _buffers.putIfAbsent(frame.srcId, () => JitterBuffer(capacity: jitterCapacity));
    for (final payload in buffer.insert(frame.seqNum, frame.payload)) {
      _received.add(ReceivedAudioFrame(
        srcId: frame.srcId,
        pcm: codec.decode(payload),
      ));
    }
  }
}
