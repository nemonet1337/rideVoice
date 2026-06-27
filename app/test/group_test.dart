import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/group/group.dart';

void main() {
  test('GroupManager starts in idle', () {
    final gm = GroupManager();
    expect(gm.state, GroupState.idle);
  });

  test('createGroup transitions to hosting', () async {
    final gm = GroupManager();
    await gm.createGroup();
    expect(gm.state, GroupState.hosting);
    expect(gm.groupId, isNotNull);
  });

  test('leaveGroup returns to idle', () async {
    final gm = GroupManager();
    await gm.createGroup();
    await gm.leaveGroup();
    expect(gm.state, GroupState.idle);
    expect(gm.groupId, isNull);
  });

  test('rotateKey cycles through rekeying', () async {
    final gm = GroupManager();
    await gm.createGroup();
    await gm.rotateKey();
    expect(gm.state, GroupState.joined);
  });
}
