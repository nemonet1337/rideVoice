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

/// App-level state machine (design doc §7).
///
/// Entering [AppState.reconnecting] starts the reconnect timer: if the
/// state has not left reconnecting within [reconnectTimeout] (30 s in the
/// design), the machine drops to [AppState.offline] automatically.
class AppStateMachine {
  static const Duration defaultReconnectTimeout = Duration(seconds: 30);

  final _log = Logger('AppStateMachine');
  final _stateController = StreamController<AppState>.broadcast();
  final Duration reconnectTimeout;
  AppState _current = AppState.idle;
  Timer? _reconnectTimer;

  AppStateMachine({this.reconnectTimeout = defaultReconnectTimeout});

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
      // §7: 接続断検知 can fire while transmitting or relaying too.
      (AppState.transmit, AppState.reconnecting) => true,
      (AppState.relaying, AppState.reconnecting) => true,
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

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (target == AppState.reconnecting) {
      _reconnectTimer = Timer(reconnectTimeout, () {
        if (_current == AppState.reconnecting) {
          _log.info('reconnect timed out after $reconnectTimeout');
          transition(AppState.offline);
        }
      });
    }
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _stateController.close();
  }
}
