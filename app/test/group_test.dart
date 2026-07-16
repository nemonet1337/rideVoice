import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ridevoice/crypto/crypto.dart';
import 'package:ridevoice/crypto/dart_crypto_provider.dart';
import 'package:ridevoice/group/group.dart';

void main() {
  final crypto = DartCryptoProvider();

  GroupManager manager({Duration? rotation}) => GroupManager(
        crypto: crypto,
        rotationPeriod: rotation ?? GroupManager.rotationInterval,
      );

  group('lifecycle', () {
    test('starts idle, hosting after createGroup, idle after leave',
        () async {
      final gm = manager();
      expect(gm.state, GroupState.idle);

      await gm.createGroup();
      expect(gm.state, GroupState.hosting);
      expect(gm.groupId, isNotNull);
      expect(gm.isHost, isTrue);
      expect(gm.groupKeyBytes, isNotNull);
      expect(gm.groupKeyBytes!.any((b) => b != 0), isTrue,
          reason: 'the group key must be real random material, not zeros');

      await gm.leaveGroup();
      expect(gm.state, GroupState.idle);
      expect(gm.groupId, isNull);
      gm.dispose();
    });

    test('dissolveGroup is host-only (§5-3)', () async {
      final host = manager();
      final invite = await host.createGroup();

      final member = manager();
      await member.joinGroup(invite);
      expect(() => member.dissolveGroup(), throwsStateError);

      await host.dissolveGroup();
      expect(host.state, GroupState.idle);
      host.dispose();
      member.dispose();
    });
  });

  group('invites (§5-2)', () {
    test('QR payload roundtrips with all required fields', () async {
      final gm = manager();
      final invite = await gm.createGroup();

      final decoded = GroupInvite.fromQrString(invite.toQrString());
      expect(decoded.groupId, invite.groupId);
      expect(decoded.inviteToken, invite.inviteToken);
      expect(decoded.bootstrapPk, invite.bootstrapPk);
      expect(hexDecode(decoded.inviteToken).length, 32);
      expect(hexDecode(decoded.bootstrapPk).length, 32);
      gm.dispose();
    });

    test('invites expire after 5 minutes and are rejected on join', () async {
      final gm = manager();
      final invite = await gm.createGroup();

      final expired = GroupInvite(
        groupId: invite.groupId,
        inviteToken: invite.inviteToken,
        bootstrapPk: invite.bootstrapPk,
        createdAt: clock.now().subtract(const Duration(minutes: 6)),
      );
      expect(expired.isExpired, isTrue);

      final joiner = manager();
      expect(() => joiner.joinGroup(expired), throwsStateError);
      gm.dispose();
      joiner.dispose();
    });

    test('malformed QR payloads are rejected', () {
      expect(() => GroupInvite.fromQrString('{"group_id":"x"}'),
          throwsA(anything));
      expect(
        () => GroupInvite.fromJson({
          'group_id': 'g',
          'invite_token': 'abcd', // 2 bytes, not 32
          'bootstrap_pk': 'ab' * 32,
          'created_at': 0,
        }),
        throwsFormatException,
      );
    });

    test('6-digit fallback code redeems the active invite (§5-1)', () async {
      final gm = manager();
      await gm.createGroup();

      final code = gm.generateFallbackCode();
      expect(code, matches(RegExp(r'^\d{6}$')));

      expect(gm.redeemFallbackCode(code), isNotNull);
      expect(gm.redeemFallbackCode('000000'), isNull);
      gm.dispose();
    });
  });

  group('membership (§5-3)', () {
    test('33rd member is rejected', () async {
      final gm = manager();
      await gm.createGroup(selfId: 'host');

      for (var i = 1; i < GroupManager.maxMembers; i++) {
        gm.addMember('rider-$i');
      }
      expect(gm.memberCount, GroupManager.maxMembers);
      expect(() => gm.addMember('rider-33'), throwsA(isA<GroupFullException>()));
      gm.dispose();
    });

    test('only the host can add members', () async {
      final host = manager();
      final invite = await host.createGroup();
      final member = manager();
      await member.joinGroup(invite);
      expect(() => member.addMember('someone'), throwsStateError);
      host.dispose();
      member.dispose();
    });
  });

  group('key distribution (§4-2)', () {
    test('ECDH → HKDF → AES-GCM envelope delivers the GK to a member',
        () async {
      final host = manager();
      final invite = await host.createGroup();

      final member = manager();
      await member.joinGroup(invite);

      final envelope =
          await host.distributeGroupKey(member.identity!.publicKey);
      await member.receiveGroupKey(
          envelope, hexDecode(invite.bootstrapPk));

      expect(member.state, GroupState.joined);
      expect(member.groupKeyBytes, host.groupKeyBytes);
      expect(member.currentEpoch, host.currentEpoch);
      host.dispose();
      member.dispose();
    });

    test('an envelope for a different group is rejected', () async {
      final host = manager();
      await host.createGroup();
      final otherHost = manager();
      final otherInvite = await otherHost.createGroup();

      final member = manager();
      await member.joinGroup(otherInvite);
      final envelope =
          await host.distributeGroupKey(member.identity!.publicKey);
      expect(
        () => member.receiveGroupKey(
            envelope, hexDecode(otherInvite.bootstrapPk)),
        throwsStateError,
      );
      host.dispose();
      otherHost.dispose();
      member.dispose();
    });

    test('an envelope opened with the wrong distributor key fails', () async {
      final host = manager();
      final invite = await host.createGroup();
      final member = manager();
      await member.joinGroup(invite);

      final envelope =
          await host.distributeGroupKey(member.identity!.publicKey);
      final wrongKey = (await crypto.generateKeyPair()).publicKey;
      expect(
        () => member.receiveGroupKey(envelope, wrongKey),
        throwsA(isA<AuthenticationException>()),
      );
      host.dispose();
      member.dispose();
    });
  });

  group('rotation (§4-3)', () {
    test('member departure rotates immediately', () async {
      final gm = manager();
      await gm.createGroup(selfId: 'host');
      gm.addMember('rider-1');
      final beforeKey = List<int>.from(gm.groupKeyBytes!);
      final epochs = <int>[];
      gm.rotations.listen(epochs.add);

      await gm.memberLeft('rider-1');

      expect(gm.currentEpoch, 1);
      expect(gm.groupKeyBytes, isNot(equals(beforeKey)));
      await Future<void>.delayed(Duration.zero);
      expect(epochs, [1]);
      gm.dispose();
    });

    test('periodic rotation fires on the configured interval', () async {
      final gm = manager(rotation: const Duration(milliseconds: 60));
      await gm.createGroup();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(gm.currentEpoch, greaterThanOrEqualTo(2),
          reason: '30-min periodic rotation (shortened for test)');
      gm.dispose();
    });

    test('manual rotation is host-only', () async {
      final host = manager();
      final invite = await host.createGroup();
      final member = manager();
      await member.joinGroup(invite);
      final envelope =
          await host.distributeGroupKey(member.identity!.publicKey);
      await member.receiveGroupKey(envelope, hexDecode(invite.bootstrapPk));

      expect(() => member.rotateKey(), throwsStateError);

      await host.rotateKey();
      expect(host.currentEpoch, 1);
      host.dispose();
      member.dispose();
    });

    test('rotated key reaches members via a fresh envelope', () async {
      final host = manager();
      final invite = await host.createGroup();
      final member = manager();
      await member.joinGroup(invite);
      var envelope =
          await host.distributeGroupKey(member.identity!.publicKey);
      await member.receiveGroupKey(envelope, hexDecode(invite.bootstrapPk));

      await host.rotateKey();
      envelope = await host.distributeGroupKey(member.identity!.publicKey);
      await member.receiveGroupKey(envelope, hexDecode(invite.bootstrapPk));

      expect(member.currentEpoch, 1);
      expect(member.groupKeyBytes, host.groupKeyBytes);
      // Grace period: the member still holds epoch 0.
      expect(member.keyRing!.keyForEpoch(0), isNotNull);
      host.dispose();
      member.dispose();
    });
  });
}
