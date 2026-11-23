// Proves TrajectoryCrux against a real LogbookService for the write side
// (the action-proposed-by-agent-loop entry it writes, named by the id the
// logbook gave it), and a fake `returned` stream for the read side,
// matched by that id, never a hash of the proposal's body alone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart'
    show ProposedForTheModelCall;
import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';
import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, LogbookReader;
import 'package:is_logbook_client/is_logbook_client.dart' as client;
import 'package:is_shapes/is_shapes.dart' show EntryId;
import 'package:test/test.dart';

String _proposal(int turn) => jsonEncode({
  'place': ProposedForTheModelCall.at(turn).toJson(),
  'program': 'model',
  'input': {
    'signIn': 'anthropic-api',
    'model': 'claude-opus-5-5',
    'request': 'ab' * 32,
  },
});

void main() {
  late Directory tmp;
  late LogbookService service;
  late client.ObjectId root;
  final turnKind = Kind.parse('turn')!;
  final proposedKind = Kind.parse('action-proposed-by-agent-loop')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_crux_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList('$uid turn action-proposed-by-agent-loop\n'.codeUnits),
    );
    service = await LogbookService.start(
      Logbook.open(Directory('${tmp.path}/logbook'))!,
      senderTable,
      File('${tmp.path}/logbook.sock'),
      readSocket: File('${tmp.path}/logbook.read.sock'),
    );
    final written = await client.LogbookWriter('${tmp.path}/logbook.sock')
        .write(turnKind, utf8.encode('root'));
    root = (written as client.Written).entry;
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  TrajectoryChain chainFromRoot() => TrajectoryChain(
    writer: LogbookWriter('${tmp.path}/logbook.sock'),
    kind: turnKind,
    tip: root,
  );

  test('writes the proposal on the chain and gives the id the logbook gave '
      'it; hands back the body of the outcome naming that id', () async {
    final returned = StreamController<ReturnedResult>();
    final crux = TrajectoryCrux(
      chain: chainFromRoot(),
      returned: returned.stream,
    );

    final writtenEntry = LogbookReader('${tmp.path}/logbook.read.sock')
        .subscribe(kinds: {proposedKind})
        .firstWhere((item) => item is Entry);
    final body = _proposal(1);
    final id = await crux.writeProposal(body);
    final entry = await writtenEntry as Entry;

    expect(id, EntryId.parse(entry.id.hex));
    expect(entry.previous, root);
    expect(utf8.decode(entry.body), body);

    final outcome = crux.outcomeNaming(id);
    // A result for some other proposal is passed over.
    returned.add((
      proposed: EntryId.of(utf8.encode('another proposal')),
      resultEntry: EntryId.of(utf8.encode('wrong-result-entry')),
      body: 'not this one',
    ));
    final resultEntry = EntryId.of(utf8.encode('the-matching-result-entry'));
    returned.add((proposed: id, resultEntry: resultEntry, body: 'this one'));

    expect(await outcome, 'this one');
    // Its result entry is reachable by the proposal's place, once.
    expect(crux.resultEntryAt(ProposedForTheModelCall.at(1)), resultEntry);
    expect(crux.resultEntryAt(ProposedForTheModelCall.at(1)), isNull);

    await crux.close();
    await returned.close();
  });

  test('an outcome that arrives before it is asked for is kept', () async {
    final returned = StreamController<ReturnedResult>.broadcast();
    final crux = TrajectoryCrux(
      chain: chainFromRoot(),
      returned: returned.stream,
    );

    final id = await crux.writeProposal(_proposal(2));
    returned.add((
      proposed: id,
      resultEntry: EntryId.of(utf8.encode('early-result-entry')),
      body: 'early',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(await crux.outcomeNaming(id), 'early');
    expect(
      crux.resultEntryAt(ProposedForTheModelCall.at(2)),
      EntryId.of(utf8.encode('early-result-entry')),
    );

    await crux.close();
    await returned.close();
  });
}
