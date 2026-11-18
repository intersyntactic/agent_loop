// Proves TrajectoryCrux against a real LogbookService for the write side
// (the action-proposed-by-agent-loop entry it writes), and a fake
// `returned` stream matching by the logbook's own entry id, the way the
// airlock actually names a proposal — not a hash of the proposal's raw
// bytes alone, which carries no trace of where it landed on the chain
// and so would never match.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';
import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, LogbookReader;
import 'package:is_logbook_client/is_logbook_client.dart' as client;
import 'package:is_shapes/is_shapes.dart' show EntryId;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late LogbookService service;
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
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  test(
    'writes the proposal, then returns the outcome of the matching '
    'returned entry, by the id the logbook assigned the written entry',
    () async {
      final root = await client.LogbookWriter('${tmp.path}/logbook.sock')
          .write(turnKind, utf8.encode('root'));
      final rootHash = (root as client.Written).entry;

      final chain = TrajectoryChain(
        writer: LogbookWriter('${tmp.path}/logbook.sock'),
        kind: turnKind,
        tip: rootHash,
      );

      final returnedController = StreamController<ReturnedResult>();
      final crux = TrajectoryCrux(
        chain: chain,
        returned: returnedController.stream,
      );

      final proposal = {'place': 1, 'program': 'model', 'input': 'x'};
      final writtenBytes = utf8.encode(jsonEncode(proposal));

      // A returned entry for a DIFFERENT proposal, which must be ignored,
      // then the matching one.
      final wrongId = EntryId.of(utf8.encode(jsonEncode({'other': true})));
      final wrongResultEntry = EntryId.of(utf8.encode('wrong-result-entry'));
      returnedController.add((
        proposed: wrongId,
        resultEntry: wrongResultEntry,
        result: {'kind': 'refused', 'why': 'not this one'},
      ));

      // Started before propose, so it can't miss the entry; awaited after,
      // so it names the fake result by the id the logbook actually assigns
      // the written entry, not a hash of its body.
      final writtenEntryFuture = LogbookReader('${tmp.path}/logbook.read.sock')
          .subscribe(kinds: {proposedKind})
          .firstWhere((item) => item is Entry);

      final outcomeFuture = crux.propose(proposal);

      final writtenEntry = await writtenEntryFuture as Entry;
      final id = EntryId.parse(writtenEntry.id.hex)!;
      final resultEntry = EntryId.of(utf8.encode('the-matching-result-entry'));
      returnedController.add((
        proposed: id,
        resultEntry: resultEntry,
        result: {'kind': 'ran', 'output': 'ok'},
      ));

      final outcome = await outcomeFuture;
      expect(outcome, {'kind': 'ran', 'output': 'ok'});

      // The result entry's own id is reachable by the proposal's place, not
      // by the wrong proposal's, and only once.
      expect(crux.resultEntryAt(1), resultEntry);
      expect(crux.resultEntryAt(1), isNull);

      // The proposed entry really landed on the chain, after root.
      expect(writtenEntry.previous, rootHash);
      expect(writtenEntry.body, writtenBytes);

      await returnedController.close();
    },
  );
}
