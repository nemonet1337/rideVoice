import 'dart:typed_data';

enum GroupState {
  idle,
  hosting,
  joining,
  joined,
  rekeying,
}

class GroupManager {
  GroupState _state = GroupState.idle;
  String? _groupId;
  Uint8List? _groupKey;

  GroupState get state => _state;
  String? get groupId => _groupId;

  Future<void> createGroup() async {
    _groupId = _generateId();
    _groupKey = Uint8List(32);
    _state = GroupState.hosting;
  }

  Future<void> joinGroup(String groupId) async {
    _groupId = groupId;
    _state = GroupState.joining;
  }

  Future<void> rotateKey() async {
    _state = GroupState.rekeying;
    _groupKey = Uint8List(32);
    _state = GroupState.joined;
  }

  Future<void> leaveGroup() async {
    _groupId = null;
    _groupKey = null;
    _state = GroupState.idle;
  }

  String _generateId() {
    return DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  }
}
