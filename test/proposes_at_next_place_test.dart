import 'dart:convert' show jsonEncode, utf8;

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart'
    show
        ActionProposedByAgentLoop,
        Done,
        PlaceInTrajectory,
        Program,
        ProposedForAnIntent,
        ProposedForTheModelCall,
        ProposedForTheReply,
        Result,
        outcomeOfProposedActionToJson;
import 'package:is_file_request_vocabulary/is_file_request_vocabulary.dart'
    show FileText, Wrote;
import 'package:is_outcome_vocabulary/is_outcome_vocabulary.dart' show Ran;
import 'package:is_relative_path_vocabulary/is_relative_path_vocabulary.dart'
    show RelativePath;
import 'package:is_shapes/is_shapes.dart' show EntryId;
import 'package:test/test.dart';

/// Records the place of each proposal it is handed, and answers each with
/// [answer], given the proposal's body and id. By default, the write ran.
final class _FakeLink implements ProposesActionsThroughTheLogbook {
  String Function(String body, EntryId proposed) answer = (_, proposed) =>
      jsonEncode(
        outcomeOfProposedActionToJson(
          proposed,
          Program.write.outcomeToJson(const Ran(Wrote(replaced: false))),
        ),
      );

  final places = <PlaceInTrajectory>[];
  final _bodies = <EntryId, String>{};

  @override
  Future<EntryId> writeProposal(String body) async {
    final ActionProposedByAgentLoop(:place) =
        ActionProposedByAgentLoop.read(body) as ActionProposedByAgentLoop; // cast-ok: a test proposal that is not one should fail the test here
    places.add(place);
    final id = EntryId.of(utf8.encode('${places.length}:$body'));
    _bodies[id] = body;
    return id;
  }

  @override
  Future<String> outcomeNaming(EntryId proposed) async =>
      answer(_bodies[proposed]!, proposed);
}

/// Writes [names] in order, one action each, then answers with them.
Result<List<String>> _writeAll(
  List<String> names, [
  List<String> done = const [],
]) => switch (names) {
  [] => Done(done),
  [final name, ...final rest] => Program.write.runOrFail(
    FileText(RelativePath(name), ''),
    then: (_) => _writeAll(rest, [...done, name]),
  ),
};

void main() {
  test('an answer that is no outcome ends the call', () async {
    final link = _FakeLink()
      ..answer = (_, proposed) => jsonEncode({
        'proposed': proposed.hex,
        'result': {'kind': 'maybe'},
      });
    await expectLater(
      runToEnd(
        _writeAll(['a.dart']),
        ProposesAtNextPlace.forIntent(link, step: 0, intent: 0),
      ),
      throwsFormatException,
    );
  });

  test('an outcome that names another proposal ends the call', () async {
    final other = EntryId.of(utf8.encode('another proposal'));
    final link = _FakeLink();
    final ran = link.answer;
    link.answer = (body, proposed) =>
        ran(body, proposed).replaceAll(proposed.hex, other.hex);
    await expectLater(
      runToEnd(
        _writeAll(['a.dart']),
        ProposesAtNextPlace.forIntent(link, step: 0, intent: 0),
      ),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('names $other'),
        ),
      ),
    );
  });

  test('two intents running at once each keep their own places', () async {
    final link = _FakeLink();
    // Intent 1 starts first and takes two actions; intent 0 takes one.
    final second = runToEnd(
      _writeAll(['b.dart', 'c.dart']),
      ProposesAtNextPlace.forIntent(link, step: 1, intent: 1),
    );
    final first = runToEnd(
      _writeAll(['a.dart']),
      ProposesAtNextPlace.forIntent(link, step: 1, intent: 0),
    );
    await Future.wait([first, second]);
    expect(link.places.toList()..sort(), [
      ProposedForAnIntent.at(1, 0, 0),
      ProposedForAnIntent.at(1, 1, 0),
      ProposedForAnIntent.at(1, 1, 1),
    ]);
  });

  test('the model call carries one action and refuses a second before '
      'writing it', () async {
    final link = _FakeLink();
    await expectLater(
      runToEnd(
        _writeAll(['a.dart', 'b.dart']),
        ProposesAtNextPlace.forTheModelCall(link, step: 1),
      ),
      throwsStateError,
    );
    expect(link.places, [ProposedForTheModelCall.at(1)]);
  });

  test("a reply's actions are numbered: build the message, then send what "
      'was built', () async {
    final link = _FakeLink();
    final sent = await runToEnd(
      _writeAll(['a.dart', 'b.dart']),
      ProposesAtNextPlace.forTheReply(link, step: 4),
    );
    expect(sent, isA<Done<List<String>>>());
    expect(link.places, [
      ProposedForTheReply.at(4, 0),
      ProposedForTheReply.at(4, 1),
    ]);
  });
}
