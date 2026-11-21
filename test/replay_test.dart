// Proves a restarted loop answers only the message it still owes, and
// resumes its places after the last one it used, so replaying a history
// never asks the model, or posts, twice for the same message.
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart' show PlaceInTrajectory;
import 'package:is_admission_vocabulary/is_admission_vocabulary.dart'
    show AddressInExternalSystem;
import 'package:is_effects/is_effects.dart'
    show FinishedReply, ModelAndSignIn, ModelName, ModelSignInName;
import 'package:is_flight_rules/is_flight_rules.dart'
    show FlightRules, ProgramsNetwork, WhatMayLeaveThisMachine;
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

ActionProposed _proposed(
  String seed,
  int turn, {
  int step = 0,
  bool model = true,
}) => ActionProposed(
  hash: _id(seed),
  place: PlaceInTrajectory.at(turn, step),
  asksTheModel: model,
);

TrajectoryStarted _started(String seed) {
  final signIn = ModelSignInName.parse('nick-claude-team')!;
  return TrajectoryStarted(
    hash: _id(seed),
    rules: FlightRules.of(
      whatMayLeaveThisMachine: WhatMayLeaveThisMachine(
        modelSignInsCallsMayGoOutAs: [signIn],
        sitesTheWebDriverMayReach: const [],
        programsNetwork: ProgramsNetwork.values.first,
      ),
      startingModel: ModelAndSignIn(
        signIn: signIn,
        model: ModelName.parse('claude-opus-5-5')!,
      ),
    )!,
  );
}

SaidByAgent _agent(String seed) => SaidByAgent(
  hash: _id(seed),
  reply: FinishedReply(text: seed),
);

void main() {
  test('a message already answered by a model call is not owed', () {
    final history = [
      _user('u1'),
      _proposed('p1', 1),
      _agent('a1'),
      _proposed('p2', 1, step: 1, model: false), // the answer
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

  test('a trajectory started under rules, with nothing proposed, owes its '
      'open notice', () {
    expect(owesOpenNotice([_started('s'), _user('u1')]), isTrue);
  });

  test('any proposal means the open notice is not owed: never a second, '
      'never a late one', () {
    expect(
      owesOpenNotice([_started('s'), _proposed('p0', 0, model: false)]),
      isFalse,
    );
    expect(
      owesOpenNotice([_started('s'), _user('u1'), _proposed('p1', 0)]),
      isFalse,
    );
  });

  test('no open notice without rules that read', () {
    expect(owesOpenNotice([_user('u1')]), isFalse);
    expect(
      owesOpenNotice([
        TrajectoryRulesUnreadable(hash: _id('s'), why: 'test'),
        _user('u1'),
      ]),
      isFalse,
    );
  });

  test('the latest place is by turn, then step; none used is null', () {
    expect(lastPlace([]), isNull);
    expect(
      lastPlace([
        _proposed('p1', 1),
        _proposed('p3', 3),
        _proposed('p2', 2, step: 5),
      ]),
      PlaceInTrajectory.at(3, 0),
    );
    expect(
      lastPlace([_proposed('p1', 2), _proposed('p2', 2, step: 1)]),
      PlaceInTrajectory.at(2, 1),
    );
  });
}
