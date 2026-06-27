package ridevoice

import 'dart:ffi';
import 'dart:typed_data';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

class RustLib extends FlutterRustBridgeBase {
  static RustLib? _instance;

  factory RustLib() {
    _instance ??= RustLib._();
    return _instance!;
  }

  RustLib._() : super(handler: RustLibPlatformHandler._());

  Future<void> init() async {
    await initForApp();
  }

  Future<Uint8List> generateKeyPair() async {
    return Uint8List(32);
  }

  Future<Uint8List> ecdh(Uint8List privateKey, Uint8List peerPublicKey) async {
    return Uint8List(32);
  }

  Future<Uint8List> encodeOpus(Int16List pcm) async {
    return Uint8List(0);
  }

  Future<Int16List> decodeOpus(Uint8List packet) async {
    return Int16List(0);
  }

  Future<Float32List> processRNNoise(Float32List frame) async {
    return Float32List(0);
  }
}

class RustLibPlatformHandler extends FlutterRustBridgePlatformHandler {
  RustLibPlatformHandler._() : super();

  @override
  bool get hasDynamicLibrary => false;

  @override
  DynamicLibrary get dynamicLibrary => throw UnimplementedError();

  @override
  bool get isWeb => false;
}

final rustLib = RustLib();
