// Proves the loop compacts on the context a reply actually left, shows the
// model a summary in place of what it covers, and never mistakes a summary
// for something the agent said.
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_docking_station/is_docking_station.dart'
    show AddressInExternalSystem;
import 'package:is_effects/is_effects.dart'
    show CutOffReply, FinishedReply, ModelReply, ModelUsage;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:test/test.dart';

ObjectId _id(String seed) => ObjectId.of(Uint8List.fromList(seed.codeUnits));

SaidByUser _user(String seed) => SaidByUser(
  hash: _id(seed),
  author: ActorId.parse('teams:u1')!,
  text: seed,
  startsTurn: true,
  address: AddressInExternalSystem.parse('teams:c1')!,
  rawEvent: null,
);

SaidByAgent _agent(String seed, {ModelUsage? usage}) => SaidByAgent(
  hash: _id(seed),
  reply: FinishedReply(text: seed, usage: usage),
);

SummaryByAgent _summary(String seed, String upTo, {ModelReply? reply}) =>
    SummaryByAgent(
      hash: _id(seed),
      reply: reply ?? FinishedReply(text: seed),
      upTo: _id(upTo),
    );

SummaryAsked _asked(String seed, int place, String upTo) => SummaryAsked(
  hash: _id(seed),
  asked: HistorySummaryAsked(place: place, upTo: _id(upTo)),
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

void main() {
  group('requestWindow', () {
    test('with no summary, everything but summary markers', () {
      final history = [
        _user('u1'),
        _agent('a1'),
        _asked('k1', 3, 'a1'),
        _user('u2'),
      ];

      expect(_hashes(requestWindow(history)), [
        _id('u1'),
        _id('a1'),
        _id('u2'),
      ]);
    });

    test('a summary stands in for its boundary and all before it; a message '
        'that arrived while summarizing is kept', () {
      final history = [
        _user('u1'),
        _agent('a1'),
        _asked('k1', 3, 'a1'),
        _user('u2'),
        _summary('s1', 'a1'),
        _agent('a2'),
      ];

      expect(_hashes(requestWindow(history)), [
        _id('s1'),
        _id('u2'),
        _id('a2'),
      ]);
    });

    test('the latest summary wins', () {
      final history = [
        _user('u1'),
        _agent('a1'),
        _summary('s1', 'a1'),
        _user('u2'),
        _agent('a2'),
        _summary('s2', 'a2'),
        _user('u3'),
      ];

      expect(_hashes(requestWindow(history)), [_id('s2'), _id('u3')]);
    });

    test('a cut-off summary is passed over for an earlier finished one', () {
      final history = [
        _user('u1'),
        _agent('a1'),
        _summary('s1', 'a1'),
        _user('u2'),
        _agent('a2'),
        _summary('s2', 'a2', reply: const CutOffReply(text: 'half')),
      ];

      expect(_hashes(requestWindow(history)), [
        _id('s1'),
        _id('u2'),
        _id('a2'),
      ]);
    });

    test('a summary whose boundary the history does not hold is passed '
        'over, not trusted', () {
      final history = [_user('u1'), _agent('a1'), _summary('s1', 'gone')];

      expect(_hashes(requestWindow(history)), [_id('u1'), _id('a1')]);
    });
  });

  group('replyOverTheLine', () {
    test('compacts when context plus output leaves less than the margin', () {
      // 1000 - 700 - 150 = 150 left.
      final history = [_user('u1'), _agent('a1', usage: _used(700, 150))];

      expect(replyOverTheLine(history, 200)?.hash, _id('a1'));
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
      final history = [_agent('a1', usage: usage)];

      expect(replyOverTheLine(history, 151)?.hash, _id('a1'));
      expect(replyOverTheLine(history, 150), isNull);
    });

    test('never guesses: no usage, or no context window, never compacts', () {
      expect(replyOverTheLine([_agent('a1')], 1 << 30), isNull);
      expect(
        replyOverTheLine([
          _agent('a1', usage: _used(999, 0, window: null)),
        ], 1 << 30),
        isNull,
      );
    });

    test('a reply a summary already covers is not over the line again', () {
      final history = [
        _user('u1'),
        _agent('a1', usage: _used(900, 50)),
        _asked('k1', 2, 'a1'),
        _summary('s1', 'a1'),
      ];

      expect(replyOverTheLine(history, 200), isNull);
    });
  });

  test('a summary call sends what the crossing answer sent, its reply, then '
      'the instruction', () {
    final over = _agent('a1', usage: _used(900, 50));
    final history = [_user('u1'), over, _user('u2')];

    final request = summaryRequest(history, over)!;

    expect(_hashes(request.covered), [_id('u1'), _id('a1')]);
    expect(
      [for (final t in request.input) (t.role, t.text)],
      [
        (ModelInputRole.user, 'u1'),
        (ModelInputRole.assistant, 'a1'),
        (ModelInputRole.user, summaryInstruction),
      ],
    );
  });

  test('HistorySummaryAsked round-trips and reads no other node as one', () {
    final asked = HistorySummaryAsked(place: 7, upTo: _id('a1'));
    final back = HistorySummaryAsked.fromJson(asked.toJson())!;

    expect((back.place, back.upTo), (7, _id('a1')));
    expect(HistorySummaryAsked.fromJson({'shape': 'UserSaid'}), isNull);
    expect(
      HistorySummaryAsked.fromJson({
        'shape': HistorySummaryAsked.shapeName,
        'place': 7,
        'upTo': 'not a hash',
      }),
      isNull,
    );
  });
}
