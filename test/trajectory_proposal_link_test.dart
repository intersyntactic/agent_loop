// Proves TrajectoryProposalLink against a real LogbookService for the write side
// (the action-proposed-by-agent-loop entry it writes, named by the id the
// logbook gave it), and a fake `returned` stream for the read side,
// matched by that id, never a hash of the proposal's body alone.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart'
    show ProposedForTheModelCall;
import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';
import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, LogbookReader, ReadUnreachable;
import 'package:is_logbook_client/is_logbook_client.dart' as client;
import 'package:is_shapes/is_shapes.dart' show EntryId;
import 'package:test/test.dart';

import 'loop_sender_table.dart';

String _proposal(int step) => jsonEncode({
  'place': ProposedForTheModelCall.at(step).toJson(),
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
  // Stands in for the assignment a chain starts from; nothing here reads it.
  final rootKind = Kind.parse('test-root')!;
  final proposedKind = Kind.parse('action-proposed-by-agent-loop')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_proposal_link_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    service = await LogbookService.start(
      Logbook.open(Directory('${tmp.path}/logbook'))!,
      loopSenderTable(uid, standIns: ['test-root']),
      File('${tmp.path}/logbook.sock'),
      readSocket: File('${tmp.path}/logbook.read.sock'),
    );
    final written = await client.LogbookWriter('${tmp.path}/logbook.sock')
        .write(rootKind, utf8.encode('root'));
    root = (written as client.Written).entry;
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  TrajectoryChain chainFromRoot() => TrajectoryChain(
    writer: LogbookWriter('${tmp.path}/logbook.sock'),
    tip: root,
  );

  test('writes the proposal on the chain and gives the id the logbook gave '
      'it; hands back the body of the outcome naming that id', () async {
    final returned = StreamController<ReturnedResult>();
    final link = TrajectoryProposalLink(
      chain: chainFromRoot(),
      returned: returned.stream,
    );

    final writtenEntry = LogbookReader('${tmp.path}/logbook.read.sock')
        .subscribe(kinds: {proposedKind})
        .firstWhere((item) => item is Entry);
    final body = _proposal(1);
    final id = await link.writeProposal(body);
    final entry = await writtenEntry as Entry;

    expect(id, EntryId.parse(entry.id.hex));
    expect(entry.previous, root);
    expect(utf8.decode(entry.body), body);

    final outcome = link.outcomeNaming(id);
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
    expect(link.resultEntryAt(ProposedForTheModelCall.at(1)), resultEntry);
    expect(link.resultEntryAt(ProposedForTheModelCall.at(1)), isNull);

    await link.close();
    await returned.close();
  });

  test('an outcome that arrives before it is asked for is kept', () async {
    final returned = StreamController<ReturnedResult>.broadcast();
    final link = TrajectoryProposalLink(
      chain: chainFromRoot(),
      returned: returned.stream,
    );

    final id = await link.writeProposal(_proposal(2));
    returned.add((
      proposed: id,
      resultEntry: EntryId.of(utf8.encode('early-result-entry')),
      body: 'early',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(await link.outcomeNaming(id), 'early');
    expect(
      link.resultEntryAt(ProposedForTheModelCall.at(2)),
      EntryId.of(utf8.encode('early-result-entry')),
    );

    await link.close();
    await returned.close();
  });

  test('a read failure on the results fails the outcome awaited, any asked '
      'for later, and ended', () async {
    final returned = StreamController<ReturnedResult>();
    final link = TrajectoryProposalLink(
      chain: chainFromRoot(),
      returned: returned.stream,
    );

    final first = await link.writeProposal(_proposal(3));
    final awaited = link.outcomeNaming(first);
    returned.addError(const ReadUnreachable('socket: gone'));

    await expectLater(awaited, throwsA(isA<ReadUnreachable>()));
    final second = await link.writeProposal(_proposal(4));
    await expectLater(
      link.outcomeNaming(second),
      throwsA(isA<ReadUnreachable>()),
    );
    await expectLater(link.ended, throwsA(isA<ReadUnreachable>()));
    await returned.close();
  });

  test('results that simply end fail ended with FeedEnded, and an outcome '
      'asked for after never hangs', () async {
    final returned = StreamController<ReturnedResult>();
    final link = TrajectoryProposalLink(
      chain: chainFromRoot(),
      returned: returned.stream,
    );

    await returned.close();

    await expectLater(link.ended, throwsA(isA<FeedEnded>()));
    final id = await link.writeProposal(_proposal(5));
    await expectLater(link.outcomeNaming(id), throwsA(isA<FeedEnded>()));
  });
}
