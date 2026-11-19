// Proves requestWindow shows the model the latest summary in place of
// everything it covers, and HistorySummarized round-trips as a turn node.
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_docking_station/is_docking_station.dart'
    show AddressInExternalSystem;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:test/test.dart';

ObjectId _id(String seed) => ObjectId.of(Uint8List.fromList(seed.codeUnits));

SaidByUser _user(String seed, String text) => SaidByUser(
  hash: _id(seed),
  author: ActorId.parse('teams:u1')!,
  text: text,
  startsTurn: true,
  address: AddressInExternalSystem.parse('teams:c1')!,
  rawEvent: null,
);

SaidByAgent _agent(String seed, String text) =>
    SaidByAgent(hash: _id(seed), text: text);

HistorySummarizedOnChain _marker(
  String seed, {
  required String summary,
  required String upTo,
}) => HistorySummarizedOnChain(
  hash: _id(seed),
  marker: HistorySummarized(summary: _id(summary), upTo: _id(upTo)),
);

void main() {
  test('with no boundary, the model sees the whole history', () {
    final history = [_user('u1', 'hi'), _agent('a1', 'hello')];

    expect(requestWindow(history), history);
  });

  test('after a boundary, the summary stands in for what it covers; the '
      'summary reply and the marker are left out, a message that arrived '
      'meanwhile is kept', () {
    final history = [
      _user('u1', 'hi'),
      _agent('a1', 'hello'),
      _user('u2', 'what was that number'),
      _agent('s1', 'they said hi; agent said hello'),
      _user('u3', 'also this'),
      _marker('m1', summary: 's1', upTo: 'a1'),
      _agent('a2', 'it was 7'),
    ];

    final window = requestWindow(history);

    expect(
      [for (final e in window) e.hash],
      [_id('s1'), _id('u2'), _id('u3'), _id('a2')],
    );
    expect(window.first, isA<SummaryOfEarlierHistory>());
    expect(
      renderTrajectoryHistory(window),
      'Summary of the conversation before this point: they said hi; agent '
      'said hello\n'
      'User: what was that number\n'
      'User: also this\n'
      'Agent: it was 7',
    );
  });

  test('the latest boundary wins over an earlier one', () {
    final history = [
      _user('u1', 'one'),
      _agent('s1', 'first summary'),
      _marker('m1', summary: 's1', upTo: 'u1'),
      _user('u2', 'two'),
      _agent('s2', 'second summary'),
      _marker('m2', summary: 's2', upTo: 'u2'),
      _user('u3', 'three'),
    ];

    expect(
      [for (final e in requestWindow(history)) e.hash],
      [_id('s2'), _id('u3')],
    );
  });

  test('a boundary naming a summary the history lacks shows the whole '
      'history, never a window that drops what it cannot place', () {
    final history = [
      _user('u1', 'one'),
      _marker('m1', summary: 'missing', upTo: 'u1'),
      _user('u2', 'two'),
    ];

    expect(
      [for (final e in requestWindow(history)) e.hash],
      [_id('u1'), _id('u2')],
    );
  });

  test('HistorySummarized round-trips as a turn node, and reads no other '
      'node as one', () {
    final marker = HistorySummarized(summary: _id('s1'), upTo: _id('u1'));
    final back = HistorySummarized.fromJson(marker.toJson());

    expect(back?.summary, marker.summary);
    expect(back?.upTo, marker.upTo);
    expect(
      HistorySummarized.fromJson({'shape': 'UserSaid', 'text': 'hi'}),
      isNull,
    );
  });
}
