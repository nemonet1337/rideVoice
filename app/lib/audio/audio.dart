import 'dart:typed_data';

enum AudioSessionState {
  idle,
  configuring,
  active,
  error,
}

abstract class AudioSessionManager {
  Future<void> configure();
  Future<void> activate();
  Future<void> deactivate();
  Future<void> routeToHfp();
  Future<void> releaseHfp();
  AudioSessionState get state;
  Stream<AudioSessionState> get stateChanges;
}

/// Capture / playback surface. One pipeline; mesh carries the frames.
abstract class AudioPipeline {
  Future<void> start();
  Future<void> stop();
  Future<void> sendFrame(Uint8List pcmData);
  Stream<Uint8List> get receivedFrames;
  bool get isRunning;
}
