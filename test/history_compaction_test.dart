// Proves the loop compacts on the context a final reply actually left, as a
// turn of its own once nothing else is owed, shows the model a summary in
// place of what it covers, never mistakes a summary for an answer, and
// proposes a marked summary at the same turn after a restart.
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart'
    show ProposedForTheModelCall, ProposedForTheReply;
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show AddressInExternalSystem;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show
        AgentCalledTools,
        AgentSaid,
        CutOffReply,
        FinishedReply,
        ModelReply,
        ModelTurn,
        ModelUsage,
        ToolAnswered,
        UserSaid;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:test/test.dart';

/// [turn] as one line, so a request's turns read as a list.
String _show(ModelTurn turn) => switch (turn) {
  UserSaid(:final text) => 'user:$text',
  AgentSaid(:final text) => 'agent:$text',
  AgentCalledTools() || ToolAnswered() => 'tools',
};

ObjectId _id(String seed) => ObjectId.of(Uint8List.fromList(seed.codeUnits));

SaidByUser _user(String seed) => SaidByUser(
  hash: _id(seed),
  author: ActorId.parse('teams:u1')!,
  text: seed,
  startsTurn: true,
  address: AddressInExternalSystem.parse('teams:c1')!,
);

/// The model call answering at [turn].
ActionProposed _call(String seed, int turn) => ActionProposed(
  hash: _id(seed),
  place: ProposedForTheModelCall.at(turn),
  program: ProposedProgram.askTheModel,
);

/// [turn]'s reply, sent.
ActionProposed _replied(String seed, int turn) => ActionProposed(
  hash: _id(seed),
  place: ProposedForTheReply.at(turn, 0),
  program: ProposedProgram.other,
);

/// The model's finished reply [seed] to the call proposed as [call].
SaidByAgent _agent(String seed, String call, {ModelUsage? usage}) =>
    SaidByAgent(
      hash: _id(seed),
      proposed: _id(call),
      reply: FinishedReply(text: seed, usage: usage),
    );

/// The marker for a summary at [turn] up to [upTo].
SummaryAsked _asked(String seed, int turn, String upTo) => SummaryAsked(
  hash: _id(seed),
  asked: HistorySummaryAsked(turn: turn, upTo: _id(upTo)),
);

/// The summary call at [turn].
ActionProposed _summaryCall(String seed, int turn) => ActionProposed(
  hash: _id(seed),
  place: ProposedForTheModelCall.at(turn),
  program: ProposedProgram.askTheModelForASummary,
);

SummaryByAgent _summary(
  String seed,
  String call,
  String upTo, {
  ModelReply? reply,
}) => SummaryByAgent(
  hash: _id(seed),
  proposed: _id(call),
  reply: reply ?? FinishedReply(text: seed),
  upTo: _id(upTo),
);

ModelUsage _used(int context, int output, {int? window = 1000}) => ModelUsage(
  input: context,
  cacheRead: 0,
  output: output,
  contextWindow: window,
);

List<ObjectId> _hashes(List<TrajectoryEvent> events) => [
  for (final e in events) e.hash,
];

/// A summary owed up to [upTo], at [turn] when already marked.
Matcher _summaryOwed(String upTo, int? turn) => isA<SummaryOwed>()
    .having((s) => s.upTo, 'upTo', _id(upTo))
    .having((s) => s.turn, 'turn', turn);

/// A model call owed to answer [after].
Matcher _answerOwed(String after) =>
    isA<ModelCallOwed>().having((s) => s.after, 'after', _id(after));

/// Turn 0 answered with a reply that left 1000 - 900 - 50 = 50 tokens.
List<TrajectoryEvent> _answeredOverTheLine() => [
  _user('u1'),
  _call('p0', 0),
  _agent('a1', 'p0', usage: _used(900, 50)),
  _replied('r0', 0),
];

void main() {
  group('requestWindow', () {
    test('with no summary, everything but the summary call', () {
      final history = [
        ..._answeredOverTheLine(),
        _asked('k1', 1, 'a1'),
        _summaryCall('p1', 1),
        _user('u2'),
      ];

      expect(_hashes(requestWindow(history)), [
        _id('u1'),
        _id('p0'),
        _id('a1'),
        _id('r0'),
        _id('u2'),
      ]);
    });

    test('a summary stands in for its boundary and all before it; a message '
        'that arrived while summarizing is kept', () {
      final history = [
        ..._answeredOverTheLine(),
        _asked('k1', 1, 'a1'),
        _summaryCall('p1', 1),
        _user('u2'),
        _summary('s1', 'p1', 'a1'),
      ];

      expect(_hashes(requestWindow(history)), [
        _id('s1'),
        _id('r0'),
        _id('u2'),
      ]);
    });

    test('the latest summary wins', () {
      final history = [
        ..._answeredOverTheLine(),
        _summary('s1', 'p1', 'a1'),
        _user('u2'),
        _call('p2', 2),
        _agent('a2', 'p2'),
        _summary('s2', 'p3', 'a2'),
        _user('u3'),
      ];

      expect(_hashes(requestWindow(history)), [_id('s2'), _id('u3')]);
    });

    test('a cut-off summary is passed over for an earlier finished one', () {
      final history = [
        ..._answeredOverTheLine(),
        _summary('s1', 'p1', 'a1'),
        _user('u2'),
        _summary('s2', 'p2', 'u2', reply: const CutOffReply(text: 'half')),
      ];

      expect(_hashes(requestWindow(history)), [
        _id('s1'),
        _id('r0'),
        _id('u2'),
      ]);
    });

    test('a summary whose boundary the history does not hold is passed '
        'over, not trusted', () {
      final history = [_user('u1'), _summary('s1', 'p1', 'gone')];

      expect(_hashes(requestWindow(history)), [_id('u1')]);
    });

    test(
      'the model reads a summary as its own notes, then what came after',
      () {
        final history = [
          ..._answeredOverTheLine(),
          _asked('k1', 1, 'a1'),
          _summaryCall('p1', 1),
          _summary('s1', 'p1', 'a1'),
          _user('u2'),
        ];

        expect(
          trajectoryInput(requestWindow(history), tools: const {}).map(_show),
          [
            'user:Your summary of this conversation before this point:\n\ns1',
            'user:u2',
          ],
        );
      },
    );
  });

  group('replyOverTheLine', () {
    test('compacts when context plus output leaves less than the margin', () {
      final history = [
        _call('p0', 0),
        // 1000 - 700 - 150 = 150 left.
        _agent('a1', 'p0', usage: _used(700, 150)),
      ];

      expect(replyOverTheLine(history, 151)?.hash, _id('a1'));
      expect(replyOverTheLine(history, 150), isNull);
    });

    test('counts cache reads and writes as context', () {
      const usage = ModelUsage(
        input: 100,
        cacheRead: 500,
        cacheCreation: 200,
        output: 50,
        contextWindow: 1000,
      );
      // 1000 - 800 - 50 = 150 left.
      final history = [_call('p0', 0), _agent('a1', 'p0', usage: usage)];

      expect(replyOverTheLine(history, 151)?.hash, _id('a1'));
      expect(replyOverTheLine(history, 150), isNull);
    });

    test('never guesses: no usage, or no context window (a reply that calls '
        'tools), never compacts', () {
      expect(
        replyOverTheLine([_call('p0', 0), _agent('a1', 'p0')], 1 << 30),
        isNull,
      );
      expect(
        replyOverTheLine([
          _call('p0', 0),
          _agent('a1', 'p0', usage: _used(999, 0, window: null)),
        ], 1 << 30),
        isNull,
      );
    });

    test('a reply a summary was asked for is never over the line again, '
        'even when that summary was refused', () {
      final history = [
        ..._answeredOverTheLine(),
        _asked('k1', 1, 'a1'),
        _summaryCall('p1', 1),
        ModelCallRefused(hash: _id('x1'), proposed: _id('p1')),
      ];

      expect(replyOverTheLine(history, 200), isNull);
    });
  });

  group('stepOwed', () {
    StepOwed? owed(List<TrajectoryEvent> history, {int? margin = 200}) =>
        stepOwed(
          history,
          tools: const {},
          latestOwn: lastPlace(history),
          compactMargin: margin,
        );

    test('a final reply over the line owes a summary at the next turn', () {
      expect(owed(_answeredOverTheLine()), _summaryOwed('a1', null));
    });

    test('without a margin, never', () {
      expect(owed(_answeredOverTheLine(), margin: null), isNull);
    });

    test('a waiting message is answered first: the margin leaves room for '
        'it', () {
      expect(owed([..._answeredOverTheLine(), _user('u2')]), _answerOwed('u2'));
    });

    test('a marker written but never proposed is proposed at its own turn, '
        'before a waiting message', () {
      expect(
        owed([..._answeredOverTheLine(), _asked('k1', 1, 'a1'), _user('u2')]),
        _summaryOwed('a1', 1),
      );
    });

    test('nothing is owed while the summary call is out', () {
      final history = [
        ..._answeredOverTheLine(),
        _asked('k1', 1, 'a1'),
        _summaryCall('p1', 1),
        _user('u2'),
      ];

      expect(owed(history), isNull);
    });

    test('a summary call answers no message', () {
      final history = [
        ..._answeredOverTheLine(),
        _asked('k1', 1, 'a1'),
        _user('u2'),
        _summaryCall('p1', 1),
        _summary('s1', 'p1', 'a1'),
      ];

      expect(owed(history), _answerOwed('u2'));
    });

    test('a refused summary is not asked for again', () {
      final history = [
        ..._answeredOverTheLine(),
        _asked('k1', 1, 'a1'),
        _summaryCall('p1', 1),
        ModelCallRefused(hash: _id('x1'), proposed: _id('p1')),
      ];

      expect(owed(history), isNull);
    });

    test("a summary's turn is used: the next answer goes after it", () {
      final history = [
        ..._answeredOverTheLine(),
        _asked('k1', 1, 'a1'),
        _summaryCall('p1', 1),
        _summary('s1', 'p1', 'a1'),
      ];

      expect(lastPlace(history), ProposedForTheModelCall.at(1));
    });

    test('a restarted chain resumes after a marker with no proposal', () {
      final history = [..._answeredOverTheLine(), _asked('k1', 1, 'a1')];

      expect(lastOwnEntry(history), _id('k1'));
    });
  });

  test('a summary call sends what the crossing answer sent, its reply, then '
      'the instruction', () {
    final history = [..._answeredOverTheLine(), _user('u2')];

    final request = summaryRequest(history, _id('a1'), tools: const {})!;

    expect(_hashes(request.covered), [_id('u1'), _id('p0'), _id('a1')]);
    expect(request.input.map(_show), [
      'user:u1',
      'agent:a1',
      'user:$summaryInstruction',
    ]);
  });

  test('HistorySummaryAsked round-trips and reads no other node as one', () {
    final asked = HistorySummaryAsked(turn: 7, upTo: _id('a1'));
    final back = HistorySummaryAsked.fromJson(asked.toJson())!;

    expect((back.turn, back.upTo), (7, _id('a1')));
    expect(HistorySummaryAsked.fromJson({'shape': 'UserSaid'}), isNull);
    expect(
      HistorySummaryAsked.fromJson({
        'shape': HistorySummaryAsked.shapeName,
        'turn': 7,
        'upTo': 'not a hash',
      }),
      isNull,
    );
    expect(
      HistorySummaryAsked.fromJson({
        'shape': HistorySummaryAsked.shapeName,
        'turn': -1,
        'upTo': _id('a1').hex,
      }),
      isNull,
    );
  });
}
