// Proves a restarted loop answers only the message it still owes, and
// resumes its places after the last one it used, so replaying a history
// never asks the model, or posts, twice for the same message.
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart'
    show ProposedForTheModelCall, ProposedForTheReply;
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show AddressInExternalSystem;
import 'package:is_effects/is_effects.dart' show FinishedReply;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:test/test.dart';

ObjectId _id(String seed) => ObjectId.of(Uint8List.fromList(seed.codeUnits));

SaidByUser _user(String seed, {bool startsTurn = true}) => SaidByUser(
  hash: _id(seed),
  author: ActorId.parse('teams:u1')!,
  text: seed,
  startsTurn: startsTurn,
  address: AddressInExternalSystem.parse('teams:c1')!,
);

/// A model call at [turn], or with [model] false, [action] of its reply.
ActionProposed _proposed(
  String seed,
  int turn, {
  int action = 0,
  bool model = true,
}) => ActionProposed(
  hash: _id(seed),
  place: model
      ? ProposedForTheModelCall.at(turn)
      : ProposedForTheReply.at(turn, action),
  asksTheModel: model,
);

/// The model's reply [seed] to the call proposed as [call].
SaidByAgent _agent(String seed, String call) => SaidByAgent(
  hash: _id(seed),
  proposed: _id(call),
  reply: FinishedReply(text: seed),
);

ModelCallRefused _refused(String seed, String call) =>
    ModelCallRefused(hash: _id(seed), proposed: _id(call));

void main() {
  test('a message already answered by a model call is not owed', () {
    final history = [
      _user('u1'),
      _proposed('p1', 1),
      _agent('a1', 'p1'),
      _proposed('p2', 1, action: 1, model: false), // the answer
    ];

    expect(unansweredTurn(history), isNull);
  });

  test('the latest message with no model call after it is owed', () {
    final history = [
      _user('u1'),
      _proposed('p1', 1),
      _agent('a1', 'p1'),
      _user('u2'),
    ];

    expect(unansweredTurn(history)?.hash, _id('u2'));
  });

  test('only the latest of several unanswered messages is owed', () {
    final history = [_user('u1'), _user('u2'), _user('u3')];

    expect(unansweredTurn(history)?.hash, _id('u3'));
  });

  test('a message that starts no turn is never owed, and does not hide an '
      'earlier one that does', () {
    expect(unansweredTurn([_user('ctx', startsTurn: false)]), isNull);
    expect(
      unansweredTurn([_user('u1'), _user('ctx', startsTurn: false)])?.hash,
      _id('u1'),
    );
  });

  test('a model call proposed but not yet answered still counts: the loop '
      'never proposes twice for one message', () {
    expect(unansweredTurn([_user('u1'), _proposed('p1', 1)]), isNull);
  });

  test('a web post after the message is not an answer to it', () {
    expect(
      unansweredTurn([_user('u1'), _proposed('p1', 1, model: false)])?.hash,
      _id('u1'),
    );
  });

  test('a reply goes where the call it answers was proposed, even when a '
      'message arrived before the reply did', () {
    final input = trajectoryInput([
      _user('u1'),
      _proposed('p1', 0),
      _user('u2'),
      _agent('a1', 'p1'),
    ]);

    expect(
      [for (final t in input) '${t.role.name}:${t.text}'],
      ['user:u1', 'assistant:a1', 'user:u2'],
    );
  });

  group('modelCallsSettled', () {
    test('a call with no end in history is not settled, so a message that '
        'arrived during it waits for its reply', () {
      final history = [_user('u1'), _proposed('p1', 0), _user('u2')];

      expect(modelCallsSettled(history, turnsUsed: 1), isFalse);
      expect(
        modelCallsSettled([...history, _agent('a1', 'p1')], turnsUsed: 1),
        isTrue,
      );
    });

    test('a refused call has ended too', () {
      expect(
        modelCallsSettled([
          _user('u1'),
          _proposed('p1', 0),
          _refused('r1', 'p1'),
        ], turnsUsed: 1),
        isTrue,
      );
    });

    test('the loop\'s latest call counts before its proposal arrives', () {
      final history = [
        _user('u1'),
        _proposed('p1', 0),
        _agent('a1', 'p1'),
        _user('u2'),
      ];

      // Turn 1 has been asked, but its proposal is not in history yet.
      expect(modelCallsSettled(history, turnsUsed: 2), isFalse);
      expect(modelCallsSettled(history, turnsUsed: 1), isTrue);
    });

    test('a loop that has asked nothing is settled', () {
      expect(modelCallsSettled([_user('u1')], turnsUsed: 0), isTrue);
    });
  });

  test('the latest place is by turn, then the reply after the model call; '
      'none used is null', () {
    expect(lastPlace([]), isNull);
    expect(
      lastPlace([
        _proposed('p1', 1),
        _proposed('p3', 3),
        _proposed('p2', 2, action: 5, model: false),
      ]),
      ProposedForTheModelCall.at(3),
    );
    expect(
      lastPlace([_proposed('p1', 2), _proposed('p2', 2, model: false)]),
      ProposedForTheReply.at(2, 0),
    );
  });
}
