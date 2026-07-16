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

  void driveToInGroup(AppStateMachine sm) {
    sm.transition(AppState.discovering);
    sm.transition(AppState.connecting);
    sm.transition(AppState.inGroup);
  }

  test('reconnecting flow', () {
    final sm = AppStateMachine();
    driveToInGroup(sm);
    expect(sm.canTransition(AppState.reconnecting), isTrue);

    sm.transition(AppState.reconnecting);
    expect(sm.current, AppState.reconnecting);

    expect(sm.canTransition(AppState.inGroup), isTrue);
    expect(sm.canTransition(AppState.offline), isTrue);
    sm.dispose();
  });

  test('§7: connection loss can interrupt transmit and relaying', () {
    final sm = AppStateMachine();
    driveToInGroup(sm);

    sm.transition(AppState.transmit);
    expect(sm.canTransition(AppState.reconnecting), isTrue);
    sm.transition(AppState.reconnecting);
    expect(sm.current, AppState.reconnecting);

    sm.transition(AppState.inGroup);
    sm.transition(AppState.relaying);
    sm.transition(AppState.reconnecting);
    expect(sm.current, AppState.reconnecting);
    sm.dispose();
  });

  test('reconnect timeout drops to offline automatically (§7: 30 s)',
      () async {
    final sm =
        AppStateMachine(reconnectTimeout: const Duration(milliseconds: 60));
    driveToInGroup(sm);
    sm.transition(AppState.reconnecting);

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(sm.current, AppState.offline);
    sm.dispose();
  });

  test('reconnect success cancels the offline timer', () async {
    final sm =
        AppStateMachine(reconnectTimeout: const Duration(milliseconds: 60));
    driveToInGroup(sm);
    sm.transition(AppState.reconnecting);
    sm.transition(AppState.inGroup); // recovered in time

    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(sm.current, AppState.inGroup,
        reason: 'timer must be cancelled on recovery');
    sm.dispose();
  });
}
