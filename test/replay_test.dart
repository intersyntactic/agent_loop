// Proves a restarted loop answers only the message it still owes, and
// resumes its places after the last one it used, so replaying a history
// never asks the model, or posts, twice for the same message.
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_docking_station/is_docking_station.dart'
    show AddressInExternalSystem;
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
  rawEvent: null,
);

ActionProposed _proposed(String seed, int place, {bool model = true}) =>
    ActionProposed(hash: _id(seed), place: place, asksTheModel: model);

SaidByAgent _agent(String seed) => SaidByAgent(hash: _id(seed), text: seed);

void main() {
  test('a message already answered by a model call is not owed', () {
    final history = [
      _user('u1'),
      _proposed('p1', 1),
      _agent('a1'),
      _proposed('p2', 2, model: false), // the Teams post
    ];

    expect(unansweredTurn(history), isNull);
  });

  test('the latest message with no model call after it is owed', () {
    final history = [
      _user('u1'),
      _proposed('p1', 1),
      _agent('a1'),
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

  test('places resume after the highest one used; none used is 0', () {
    expect(lastPlace([]), 0);
    expect(
      lastPlace([_proposed('p1', 1), _proposed('p3', 3), _proposed('p2', 2)]),
      3,
    );
    expect(
      lastPlace([
        ActionProposed(hash: _id('x'), place: null, asksTheModel: true),
      ]),
      0,
    );
  });
}
