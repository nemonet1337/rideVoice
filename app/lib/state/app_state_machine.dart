import 'dart:async';
import 'package:logging/logging.dart';

enum AppState {
  idle,
  discovering,
  connecting,
  inGroup,
  transmit,
  relaying,
  reconnecting,
  offline,
}

class AppStateMachine {
  final _log = Logger('AppStateMachine');
  final _stateController = StreamController<AppState>.broadcast();
  AppState _current = AppState.idle;

  AppState get current => _current;
  Stream<AppState> get states => _stateController.stream;

  bool canTransition(AppState target) {
    return switch ((_current, target)) {
      (AppState.idle, AppState.discovering) => true,
      (AppState.idle, AppState.connecting) => true,
      (AppState.discovering, AppState.connecting) => true,
      (AppState.discovering, AppState.idle) => true,
      (AppState.connecting, AppState.inGroup) => true,
      (AppState.connecting, AppState.idle) => true,
      (AppState.connecting, AppState.offline) => true,
      (AppState.inGroup, AppState.transmit) => true,
      (AppState.inGroup, AppState.relaying) => true,
      (AppState.inGroup, AppState.idle) => true,
      (AppState.transmit, AppState.inGroup) => true,
      (AppState.relaying, AppState.inGroup) => true,
      (AppState.inGroup, AppState.reconnecting) => true,
      (AppState.reconnecting, AppState.inGroup) => true,
      (AppState.reconnecting, AppState.offline) => true,
      (AppState.reconnecting, AppState.idle) => true,
      (AppState.offline, AppState.discovering) => true,
      (AppState.offline, AppState.idle) => true,
      _ => false,
    };
  }

  void transition(AppState target) {
    if (!canTransition(target)) {
      _log.warning('Invalid transition $_current -> $target');
      return;
    }
    _log.info('$_current -> $target');
    _current = target;
    _stateController.add(_current);
  }

  void dispose() {
    _stateController.close();
  }
}
