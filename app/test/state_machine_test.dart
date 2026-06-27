import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/state/app_state_machine.dart';

void main() {
  test('AppStateMachine starts in idle', () {
    final sm = AppStateMachine();
    expect(sm.current, AppState.idle);
    sm.dispose();
  });

  test('valid transitions succeed', () {
    final sm = AppStateMachine();
    expect(sm.canTransition(AppState.discovering), isTrue);
    sm.transition(AppState.discovering);
    expect(sm.current, AppState.discovering);

    expect(sm.canTransition(AppState.connecting), isTrue);
    sm.transition(AppState.connecting);
    expect(sm.current, AppState.connecting);

    expect(sm.canTransition(AppState.inGroup), isTrue);
    sm.dispose();
  });

  test('invalid transitions are blocked', () {
    final sm = AppStateMachine();
    sm.transition(AppState.inGroup);
    expect(sm.current, AppState.idle);

    sm.transition(AppState.transmit);
    expect(sm.current, AppState.idle);
    sm.dispose();
  });

  test('reconnecting flow', () {
    final sm = AppStateMachine();
    sm.transition(AppState.discovering);
    sm.transition(AppState.connecting);
    sm.transition(AppState.inGroup);
    expect(sm.canTransition(AppState.reconnecting), isTrue);

    sm.transition(AppState.reconnecting);
    expect(sm.current, AppState.reconnecting);

    expect(sm.canTransition(AppState.inGroup), isTrue);
    expect(sm.canTransition(AppState.offline), isTrue);
    sm.dispose();
  });
}
