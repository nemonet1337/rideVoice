import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:uuid/uuid.dart';

import '../crypto/crypto.dart';
import '../crypto/group_crypto.dart';

enum GroupState {
  idle,
  hosting,
  joining,
  joined,
  rekeying,
}

enum RotationTrigger { memberLeft, periodic, manual }

/// QR-code payload for group joining (design doc §5-2).
class GroupInvite {
  static const Duration validity = Duration(minutes: 5);

  final String groupId;
  final String inviteToken; // 32 bytes, hex
  final String bootstrapPk; // creator's X25519 public key, hex
  final DateTime createdAt;

  GroupInvite({
    required this.groupId,
    required this.inviteToken,
    required this.bootstrapPk,
    required this.createdAt,
  });

  bool get isExpired => clock.now().difference(createdAt) > validity;

  Map<String, dynamic> toJson() => {
        'group_id': groupId,
        'invite_token': inviteToken,
        'bootstrap_pk': bootstrapPk,
        'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
      };

  /// The string embedded in the QR code.
  String toQrString() => jsonEncode(toJson());

  factory GroupInvite.fromJson(Map<String, dynamic> json) {
    final token = json['invite_token'] as String;
    final pk = json['bootstrap_pk'] as String;
    if (hexDecode(token).length != 32) {
      throw const FormatException('invite_token must be 32 bytes');
    }
    if (hexDecode(pk).length != 32) {
      throw const FormatException('bootstrap_pk must be 32 bytes');
    }
    return GroupInvite(
      groupId: json['group_id'] as String,
      inviteToken: token,
      bootstrapPk: pk,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json['created_at'] as int) * 1000),
    );
  }

  factory GroupInvite.fromQrString(String qr) =>
      GroupInvite.fromJson(jsonDecode(qr) as Map<String, dynamic>);
}

/// Encrypted group-key delivery (design doc §4-2 steps 4-7): the GK is
/// sealed with the ECDH/HKDF session key between the distributing head and
/// the joining member.
class GroupKeyEnvelope {
  final String groupId;
  final int epoch;
  final Uint8List nonce;
  final Uint8List sealedKey; // ciphertext || tag

  GroupKeyEnvelope({
    required this.groupId,
    required this.epoch,
    required this.nonce,
    required this.sealedKey,
  });
}

class GroupFullException implements Exception {
  @override
  String toString() =>
      'GroupFullException: group already has ${GroupManager.maxMembers} members';
}

/// Group lifecycle and key management (design doc §4, §5).
class GroupManager {
  static const int maxMembers = 32;
  static const Duration rotationInterval = Duration(minutes: 30);
  static const String _gkAadPrefix = 'ridevoice-gk';

  final CryptoProvider crypto;
  final Duration rotationPeriod;

  GroupState _state = GroupState.idle;
  String? _groupId;
  bool _isHost = false;
  KeyPair? _identity;
  GroupKeyRing? _keyRing;
  GroupInvite? _activeInvite;
  String? _fallbackCode;
  Timer? _rotationTimer;
  final _members = <String>{};
  final _rotationController = StreamController<int>.broadcast();

  GroupManager({
    required this.crypto,
    this.rotationPeriod = rotationInterval,
  });

  GroupState get state => _state;
  String? get groupId => _groupId;
  bool get isHost => _isHost;
  int get memberCount => _members.length;
  GroupKeyRing? get keyRing => _keyRing;
  KeyPair? get identity => _identity;

  /// Emits the new epoch after every rotation.
  Stream<int> get rotations => _rotationController.stream;

  Uint8List? get groupKeyBytes => _keyRing?.current.keyBytes;
  int get currentEpoch => _keyRing?.current.epoch ?? 0;

  // -----------------------------------------------------------------
  // Creation & invites (§5-1, §5-2)
  // -----------------------------------------------------------------

  /// Creates a group as host: fresh identity keypair, random 256-bit GK,
  /// and a QR invite valid for 5 minutes.
  Future<GroupInvite> createGroup({String? selfId}) async {
    _identity ??= await crypto.generateKeyPair();
    _groupId = const Uuid().v4();
    _keyRing = GroupKeyRing(GroupKeyData(_randomKey(), 0));
    _isHost = true;
    _members
      ..clear()
      ..add(selfId ?? 'host');
    _state = GroupState.hosting;
    _startRotationTimer();
    return createInvite();
  }

  /// Regenerates the invite token (host only, §5-3 再生成可能).
  GroupInvite createInvite() {
    _requireHost('create an invite');
    final invite = GroupInvite(
      groupId: _groupId!,
      inviteToken: hexEncode(_randomBytes(32)),
      bootstrapPk: hexEncode(_identity!.publicKey),
      createdAt: clock.now(),
    );
    _activeInvite = invite;
    _fallbackCode = null;
    return invite;
  }

  /// 6-digit fallback code spoken aloud instead of scanning the QR
  /// (design doc §5-1 Fallback).
  String generateFallbackCode() {
    _requireHost('generate a fallback code');
    if (_activeInvite == null || _activeInvite!.isExpired) {
      createInvite();
    }
    final code = (Random.secure().nextInt(900000) + 100000).toString();
    _fallbackCode = code;
    return code;
  }

  /// Resolves a spoken code back to the invite. Returns null for wrong or
  /// expired codes.
  GroupInvite? redeemFallbackCode(String code) {
    if (_fallbackCode == null || code != _fallbackCode) return null;
    final invite = _activeInvite;
    if (invite == null || invite.isExpired) return null;
    return invite;
  }

  /// Validates the invite the host presented (§5-3: expired invites and
  /// full groups are rejected) and prepares to receive the group key.
  Future<void> joinGroup(GroupInvite invite, {String? selfId}) async {
    if (invite.isExpired) {
      throw StateError('invite expired (valid ${GroupInvite.validity})');
    }
    _identity ??= await crypto.generateKeyPair();
    _groupId = invite.groupId;
    _isHost = false;
    _state = GroupState.joining;
  }

  // -----------------------------------------------------------------
  // Membership (§5-3)
  // -----------------------------------------------------------------

  /// Registers a member (host side). Throws [GroupFullException] at the
  /// 32-member cap so the UI can surface the rejection.
  void addMember(String memberId) {
    _requireHost('add members');
    if (_members.contains(memberId)) return;
    if (_members.length >= maxMembers) {
      throw GroupFullException();
    }
    _members.add(memberId);
  }

  /// Handles a member leaving: §4-3 requires an immediate rotation so the
  /// departed device cannot decrypt further audio.
  Future<void> memberLeft(String memberId) async {
    if (!_members.remove(memberId)) return;
    if (_isHost) {
      await rotateKey(trigger: RotationTrigger.memberLeft);
    }
  }

  // -----------------------------------------------------------------
  // Key distribution & rotation (§4-2, §4-3)
  // -----------------------------------------------------------------

  /// Seals the current GK for [memberPublicKey] (ECDH → HKDF → AES-GCM).
  Future<GroupKeyEnvelope> distributeGroupKey(Uint8List memberPublicKey) async {
    final identity = _identity;
    final keyRing = _keyRing;
    final groupId = _groupId;
    if (identity == null || keyRing == null || groupId == null) {
      throw StateError('no active group');
    }
    final shared = await crypto.ecdh(identity.privateKey, memberPublicKey);
    final sessionKey = await crypto.deriveKey(shared, _sessionSalt(groupId));
    final nonce = await crypto.generateNonce();
    final sealed = await crypto.encrypt(
      keyRing.current.keyBytes,
      sessionKey,
      nonce,
      aad: _gkAad(groupId, keyRing.current.epoch),
    );
    return GroupKeyEnvelope(
      groupId: groupId,
      epoch: keyRing.current.epoch,
      nonce: nonce,
      sealedKey: sealed,
    );
  }

  /// Opens a received GK envelope using the distributor's public key.
  /// First delivery initialises the ring; later ones must carry a newer
  /// epoch (rotation) or they are rejected.
  Future<void> receiveGroupKey(
    GroupKeyEnvelope envelope,
    Uint8List distributorPublicKey,
  ) async {
    final identity = _identity;
    if (identity == null || _groupId == null) {
      throw StateError('joinGroup must be called first');
    }
    if (envelope.groupId != _groupId) {
      throw StateError('envelope for a different group');
    }
    final shared = await crypto.ecdh(identity.privateKey, distributorPublicKey);
    final sessionKey = await crypto.deriveKey(shared, _sessionSalt(_groupId!));
    final keyBytes = await crypto.decrypt(
      envelope.sealedKey,
      sessionKey,
      envelope.nonce,
      aad: _gkAad(envelope.groupId, envelope.epoch),
    );
    final key = GroupKeyData(keyBytes, envelope.epoch);
    if (_keyRing == null) {
      _keyRing = GroupKeyRing(key);
    } else {
      _keyRing!.install(key);
    }
    _state = GroupState.joined;
  }

  /// Rotates the GK (§4-3). Manual rotation is restricted to the host;
  /// memberLeft/periodic triggers fire internally.
  Future<void> rotateKey({RotationTrigger trigger = RotationTrigger.manual}) async {
    final keyRing = _keyRing;
    if (keyRing == null) throw StateError('no active group');
    if (trigger == RotationTrigger.manual) {
      _requireHost('rotate the key manually');
    }
    final previousState = _state;
    _state = GroupState.rekeying;
    keyRing.rotate(_randomKey());
    _rotationController.add(keyRing.current.epoch);
    _state =
        previousState == GroupState.rekeying ? GroupState.joined : previousState;
  }

  // -----------------------------------------------------------------
  // Teardown (§5-3)
  // -----------------------------------------------------------------

  Future<void> leaveGroup() async {
    _reset();
  }

  /// Dissolving the whole group is host-only (§5-3).
  Future<void> dissolveGroup() async {
    _requireHost('dissolve the group');
    _reset();
  }

  void dispose() {
    _rotationTimer?.cancel();
    _rotationController.close();
  }

  void _reset() {
    _rotationTimer?.cancel();
    _rotationTimer = null;
    _groupId = null;
    _keyRing = null;
    _isHost = false;
    _activeInvite = null;
    _fallbackCode = null;
    _members.clear();
    _state = GroupState.idle;
  }

  void _startRotationTimer() {
    _rotationTimer?.cancel();
    _rotationTimer = Timer.periodic(rotationPeriod, (_) {
      if (_keyRing != null && _isHost) {
        rotateKey(trigger: RotationTrigger.periodic);
      }
    });
  }

  void _requireHost(String action) {
    if (!_isHost) {
      throw StateError('only the host can $action');
    }
  }

  Uint8List _sessionSalt(String groupId) =>
      Uint8List.fromList(utf8.encode(groupId));

  Uint8List _gkAad(String groupId, int epoch) =>
      Uint8List.fromList(utf8.encode('$_gkAadPrefix:$groupId:$epoch'));

  Uint8List _randomKey() => _randomBytes(32);

  Uint8List _randomBytes(int length) {
    final random = Random.secure();
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = random.nextInt(256);
    }
    return bytes;
  }
}
