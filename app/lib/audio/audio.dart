import 'dart:typed_data';

enum AudioMode { online, offline }

enum AudioSessionState {
  idle,
  configuring,
  active,
  error,
}

abstract class AudioSessionManager {
  Future<void> configure({required AudioMode mode});
  Future<void> activate();
  Future<void> deactivate();
  Future<void> routeToHfp();
  Future<void> releaseHfp();
  AudioSessionState get state;
  Stream<AudioSessionState> get stateChanges;
}

abstract class AudioPipeline {
  Future<void> start({required AudioMode mode});
  Future<void> stop();
  Future<void> sendFrame(Uint8List pcmData);
  Stream<Uint8List> get receivedFrames;
  bool get isRunning;
  AudioMode get mode;
}
