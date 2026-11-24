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
    show
        CalledToolName,
        FinishedReply,
        Origin,
        ProposedToolCalls,
        SignIn,
        ToolCall,
        ToolCallId,
        ToolInput,
        WebPath;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show
        AgentCalledTools,
        AgentSaid,
        ModelTurn,
        ToolAnswered,
        ToolFailed,
        ToolRan,
        ToolRefused,
        ToolResult,
        UserSaid;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:is_tools_api/is_tools_api.dart'
    show Fetch, Input, OneActionTool;
import 'package:test/test.dart';

/// [turn] as one line, so a request's turns read as a list.
String _show(ModelTurn turn) => switch (turn) {
  UserSaid(:final text) => 'user:$text',
  AgentSaid(:final text) => 'agent:$text',
  AgentCalledTools(:final calls) =>
    'calls:${[for (final c in calls) '${c.id} ${c.name.asSent}'].join(',')}',
  ToolAnswered(:final callId, result: ToolRan(:final text)) =>
    'answer:$callId ran $text',
  ToolAnswered(:final callId, result: ToolFailed(:final text)) =>
    'answer:$callId failed $text',
  ToolAnswered(:final callId, result: ToolRefused(:final why)) =>
    'answer:$callId refused $why',
};

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

/// A tool's fetch for the [call]th call of [turn]'s reply.
ActionProposed _fetch(String seed, int turn, {int call = 0}) => ActionProposed(
  hash: _id(seed),
  place: ProposedForAnIntent.at(turn, call, 0),
  program: ProposedProgram.fetchFromWeb,
);

/// The fetch proposed as [fetch] ended, and the model hears [result].
FetchEnded _fetched(ToolResult result, String fetch) => FetchEnded(
  hash: _id('end of $fetch'),
  proposed: _id(fetch),
  result: result,
);

/// The model's reply [seed] to the call proposed as [call]: a finished
/// reply, or with [calls], a proposal of them.
SaidByAgent _agent(String seed, String call, {List<ToolCall>? calls}) =>
    SaidByAgent(
      hash: _id(seed),
      proposed: _id(call),
      reply: calls == null
          ? FinishedReply(text: seed)
          : ProposedToolCalls(text: 'Let me look.', calls: calls),
    );

/// A call the model made, as [id], to the tool it named [name].
ToolCall _call(String id, String name) => ToolCall(
  id: ToolCallId.parse(id)!,
  name: CalledToolName.fromSent(name),
  input: ToolInput.parse('{}')!,
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

final _callsListDocuments = [_call('toolu_1', 'list_documents')];

const _threeFiles = ToolRan('3 files');

ModelCallRefused _refused(String seed, String call) =>
    ModelCallRefused(hash: _id(seed), proposed: _id(call));

/// [turn]'s model call, its reply calling list_documents, and the fetch
/// that ran for it.
List<TrajectoryEvent> _fetchedOnce(int turn) => [
  _proposed('p$turn', turn),
  _agent('a$turn', 'p$turn', calls: _callsListDocuments),
  _fetch('f$turn', turn),
  _fetched(_threeFiles, 'f$turn'),
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
      [for (final t in input) _show(t)],
      ['user:u1', 'agent:a1', 'user:u2'],
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
        _agent('a1', 'p1', calls: _callsListDocuments),
        _fetch('f1', 0),
      ];
      final latest = ProposedForAnIntent.at(0, 0, 0);

      expect(actionsSettled(history, latestOwn: latest), isFalse);
      expect(
        actionsSettled([
          ...history,
          _fetched(_threeFiles, 'f1'),
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
      _agent('a1', 'p1', calls: _callsListDocuments),
    ];

    test('a reply that calls a given tool owes its action at the call\'s '
        'own intent', () {
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
          [...fetching, _fetched(_threeFiles, 'f1')],
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
    test('a tool call\'s answer follows the call, even when a message '
        'arrived before it ended', () {
      final input = trajectoryInput([
        _user('u1'),
        _proposed('p1', 0),
        _agent('a1', 'p1', calls: _callsListDocuments),
        _fetch('f1', 0),
        _user('u2'),
        _fetched(_threeFiles, 'f1'),
      ], tools: _tools);

      expect(
        [for (final t in input) _show(t)],
        [
          'user:u1',
          'calls:toolu_1 list_documents',
          'answer:toolu_1 ran 3 files',
          'user:u2',
        ],
      );
    });

    test('a call to a tool never offered is answered that it failed, with '
        'no fetch, never that it was refused', () {
      final input = trajectoryInput([
        _user('u1'),
        _proposed('p1', 0),
        _agent('a1', 'p1', calls: _callsListDocuments),
      ], tools: const {});

      expect(
        _show(input.last),
        'answer:toolu_1 failed no tool named "list_documents"',
      );
    });

    test('a call whose fetch has not ended is still answered, so no call '
        'is ever left without one', () {
      final input = trajectoryInput([
        _user('u1'),
        _proposed('p1', 0),
        _agent('a1', 'p1', calls: _callsListDocuments),
        _fetch('f1', 0),
      ], tools: _tools);

      expect(_show(input.last), 'answer:toolu_1 failed ${notRun.text}');
    });

    test('several calls in one reply are answered in the order made, each '
        'under its own id', () {
      final input = trajectoryInput([
        _user('u1'),
        _proposed('p1', 0),
        _agent(
          'a1',
          'p1',
          calls: [
            _call('toolu_1', 'list_documents'),
            _call('toolu_2', 'web.fetch'),
            _call('toolu_3', 'list_documents'),
          ],
        ),
        _fetch('f1', 0),
        _fetched(_threeFiles, 'f1'),
        _fetch('f3', 0, call: 2),
        _fetched(const ToolRefused('the airlock denied it'), 'f3'),
      ], tools: _tools);

      expect(
        [for (final t in input.skip(1)) _show(t)],
        [
          'calls:toolu_1 list_documents,toolu_2 web.fetch,toolu_3 list_documents',
          'answer:toolu_1 ran 3 files',
          'answer:toolu_2 failed no tool named "web.fetch"',
          'answer:toolu_3 refused the airlock denied it',
        ],
      );
    });
  });

  group('stepOwed with several calls', () {
    final asked = [
      _user('u1'),
      _proposed('p1', 0),
      _agent(
        'a1',
        'p1',
        calls: [
          _call('toolu_1', 'list_documents'),
          _call('toolu_2', 'web.fetch'),
          _call('toolu_3', 'list_documents'),
        ],
      ),
    ];

    test('runs the calls one at a time, each at its own intent, skipping '
        "one that can't run, then asks the model", () {
      expect(
        stepOwed(
          asked,
          tools: _tools,
          latestOwn: ProposedForTheModelCall.at(0),
        ),
        isA<ToolActionOwed>().having(
          (s) => s.place,
          'place',
          ProposedForAnIntent.at(0, 0, 0),
        ),
      );
      final first = [...asked, _fetch('f1', 0), _fetched(_threeFiles, 'f1')];
      expect(
        stepOwed(first, tools: _tools, latestOwn: lastPlace(first)),
        isA<ToolActionOwed>().having(
          (s) => s.place,
          'place',
          ProposedForAnIntent.at(0, 2, 0),
        ),
      );
      final both = [
        ...first,
        _fetch('f3', 0, call: 2),
        _fetched(_threeFiles, 'f3'),
      ];
      expect(
        stepOwed(both, tools: _tools, latestOwn: lastPlace(both)),
        isA<ModelCallOwed>().having((s) => s.after, 'after', _id('a1')),
      );
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
