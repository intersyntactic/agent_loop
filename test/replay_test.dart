// Proves a restarted loop answers only the message it still owes, and
// resumes its places after the last one it used, so replaying a history
// never asks the model, or posts, twice for the same message.
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart'
    show ProposedForAnIntent, ProposedForTheModelCall, ProposedForTheReply;
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show AddressInExternalSystem;
import 'package:is_effects/is_effects.dart'
    show FinishedReply, Origin, SignIn, WebPath;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:is_tools_api/is_tools_api.dart'
    show Fetch, Input, OneActionTool;
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
  program: model ? ProposedProgram.askTheModel : ProposedProgram.other,
);

/// A tool's fetch at [turn]'s one intent.
ActionProposed _fetch(String seed, int turn) => ActionProposed(
  hash: _id(seed),
  place: ProposedForAnIntent.at(turn, 0, 0),
  program: ProposedProgram.fetchFromWeb,
);

/// The fetch proposed as [fetch] ended, giving [text].
FetchEnded _fetched(String text, String fetch, {bool isError = false}) =>
    FetchEnded(
      hash: _id('end of $fetch'),
      proposed: _id(fetch),
      text: text,
      isError: isError,
    );

/// The model's reply [seed] to the call proposed as [call], or [text] when
/// given.
SaidByAgent _agent(String seed, String call, {String? text}) => SaidByAgent(
  hash: _id(seed),
  proposed: _id(call),
  reply: FinishedReply(text: text ?? seed),
);

final _graph = Origin.parse('https://graph.microsoft.com')!;

final _listDocuments = OneActionTool.of(
  name: 'list_documents',
  description: 'Lists the channel folder. Returns the first page only.',
  input: Input.none,
  action: Fetch(
    _graph,
    WebPath.parse('/v1.0/drives/b!xyz/items/01F/children')!,
    SignIn.parse('enspyr-test')!,
  ),
);

final _tools = {_listDocuments.name: _listDocuments};

const _callsListDocuments =
    'Let me look.\n<tool_call>{"name": "list_documents"}</tool_call>';

ModelCallRefused _refused(String seed, String call) =>
    ModelCallRefused(hash: _id(seed), proposed: _id(call));

/// [turn]'s model call, its reply calling list_documents, and the fetch
/// that ran for it.
List<TrajectoryEvent> _fetchedOnce(int turn) => [
  _proposed('p$turn', turn),
  _agent('a$turn', 'p$turn', text: _callsListDocuments),
  _fetch('f$turn', turn),
  _fetched('3 files', 'f$turn'),
];

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
    ], tools: const {});

    expect(
      [for (final t in input) '${t.role.name}:${t.text}'],
      ['user:u1', 'assistant:a1', 'user:u2'],
    );
  });

  group('actionsSettled', () {
    test('a call with no end in history is not settled, so a message that '
        'arrived during it waits for its reply', () {
      final history = [_user('u1'), _proposed('p1', 0), _user('u2')];
      final latest = ProposedForTheModelCall.at(0);

      expect(actionsSettled(history, latestOwn: latest), isFalse);
      expect(
        actionsSettled([...history, _agent('a1', 'p1')], latestOwn: latest),
        isTrue,
      );
    });

    test('a refused call has ended too', () {
      expect(
        actionsSettled([
          _user('u1'),
          _proposed('p1', 0),
          _refused('r1', 'p1'),
        ], latestOwn: ProposedForTheModelCall.at(0)),
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
      expect(
        actionsSettled(history, latestOwn: ProposedForTheModelCall.at(1)),
        isFalse,
      );
      expect(
        actionsSettled(history, latestOwn: ProposedForTheModelCall.at(0)),
        isTrue,
      );
    });

    test('a fetch with no end is not settled; one that ended is', () {
      final history = [
        _user('u1'),
        _proposed('p1', 0),
        _agent('a1', 'p1', text: _callsListDocuments),
        _fetch('f1', 0),
      ];
      final latest = ProposedForAnIntent.at(0, 0, 0);

      expect(actionsSettled(history, latestOwn: latest), isFalse);
      expect(
        actionsSettled([
          ...history,
          _fetched('3 files', 'f1'),
        ], latestOwn: latest),
        isTrue,
      );
    });

    test('a loop that has asked nothing is settled', () {
      expect(actionsSettled([_user('u1')], latestOwn: null), isTrue);
    });
  });

  group('stepOwed', () {
    final asked = [
      _user('u1'),
      _proposed('p1', 0),
      _agent('a1', 'p1', text: _callsListDocuments),
    ];

    test('a reply that calls a given tool owes its action at the turn\'s '
        'one intent', () {
      final step = stepOwed(
        asked,
        tools: _tools,
        latestOwn: ProposedForTheModelCall.at(0),
      );

      expect(
        step,
        isA<ToolActionOwed>()
            .having((s) => s.place, 'place', ProposedForAnIntent.at(0, 0, 0))
            .having((s) => s.tool, 'tool', same(_listDocuments)),
      );
    });

    test('the tool runs first even when a message arrived meanwhile, so '
        'its result is in the next request', () {
      expect(
        stepOwed(
          [...asked, _user('u2')],
          tools: _tools,
          latestOwn: ProposedForTheModelCall.at(0),
        ),
        isA<ToolActionOwed>(),
      );
    });

    test('nothing is owed while the fetch is under way, and a model call '
        'once it has ended', () {
      final fetching = [...asked, _fetch('f1', 0)];
      final latest = ProposedForAnIntent.at(0, 0, 0);

      expect(stepOwed(fetching, tools: _tools, latestOwn: latest), isNull);
      expect(
        stepOwed(
          [...fetching, _fetched('3 files', 'f1')],
          tools: _tools,
          latestOwn: latest,
        ),
        isA<ModelCallOwed>().having((s) => s.after, 'after', _id('a1')),
      );
    });

    test('a call to a tool the trajectory was not given runs nothing: the '
        'model is asked again, told why', () {
      expect(
        stepOwed(
          asked,
          tools: const {},
          latestOwn: ProposedForTheModelCall.at(0),
        ),
        isA<ModelCallOwed>(),
      );
    });

    test('a reply that answers owes nothing', () {
      expect(
        stepOwed(
          [_user('u1'), _proposed('p1', 0), _agent('a1', 'p1')],
          tools: _tools,
          latestOwn: ProposedForTheModelCall.at(0),
        ),
        isNull,
      );
    });

    test('a restarted loop resumes a tool call where it left off', () {
      // Caught up with the fetch's end in history: latestOwn is lastPlace.
      final history = [..._fetchedOnce(0)];

      expect(
        stepOwed(history, tools: _tools, latestOwn: lastPlace(history)),
        isA<ModelCallOwed>(),
      );
    });

    test('a message that keeps calling tools is stopped after '
        '$maxModelCallsPerMessage model calls, and told once', () {
      final history = [
        _user('u1'),
        for (var turn = 0; turn < maxModelCallsPerMessage; turn++)
          ..._fetchedOnce(turn),
      ];
      final latest = lastPlace(history);

      expect(
        stepOwed(history, tools: _tools, latestOwn: latest),
        isA<ModelCallsSpent>().having(
          (s) => s.turn,
          'turn',
          maxModelCallsPerMessage - 1,
        ),
      );
      final told = [
        ...history,
        _proposed('notice', maxModelCallsPerMessage - 1, model: false),
      ];
      expect(stepOwed(told, tools: _tools, latestOwn: lastPlace(told)), isNull);
      // A new message starts a fresh count.
      expect(
        stepOwed(
          [...told, _user('u2')],
          tools: _tools,
          latestOwn: lastPlace(told),
        ),
        isA<ModelCallOwed>(),
      );
    });
  });

  group('trajectoryInput with tools', () {
    test('a tool call\'s result follows the call, even when a message '
        'arrived before it ended', () {
      final input = trajectoryInput([
        _user('u1'),
        _proposed('p1', 0),
        _agent('a1', 'p1', text: _callsListDocuments),
        _fetch('f1', 0),
        _user('u2'),
        _fetched('3 files', 'f1'),
      ], tools: _tools);

      expect(
        [for (final t in input) '${t.role.name}:${t.text}'],
        [
          'user:u1',
          'assistant:$_callsListDocuments',
          'user:${toolResultText('3 files', name: 'list_documents', isError: false)}',
          'user:u2',
        ],
      );
    });

    test('a call that cannot run is answered with why, as an error, with '
        'no fetch', () {
      final input = trajectoryInput([
        _user('u1'),
        _proposed('p1', 0),
        _agent('a1', 'p1', text: _callsListDocuments),
      ], tools: const {});

      expect(
        input.last.text,
        toolResultText(
          'there is no tool named "list_documents"',
          name: 'list_documents',
          isError: true,
        ),
      );
    });

    test('a call whose fetch has not ended has no result yet', () {
      final input = trajectoryInput([
        _user('u1'),
        _proposed('p1', 0),
        _agent('a1', 'p1', text: _callsListDocuments),
        _fetch('f1', 0),
      ], tools: _tools);

      expect(input.last.text, _callsListDocuments);
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
