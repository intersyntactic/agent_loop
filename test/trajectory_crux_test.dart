// Proves TrajectoryCrux against a real LogbookService for the write side
// (the action-proposed-by-agent-loop entry it writes), and a fake
// `returned` stream for the match-by-EntryId-of-raw-bytes rule
// airlock-api-04 confirmed directly (2026-11-18): not the EntryHash a
// write's `ok` gives back, which depends on chain position and so would
// never match.
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

  test('writes the proposal, then returns the outcome of the matching '
      'returned entry, by EntryId of the raw proposal bytes', () async {
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

    // A returned entry for a DIFFERENT proposal, which must be ignored,
    // then the matching one.
    final wrongId = EntryId.of(utf8.encode(jsonEncode({'other': true})));
    final wrongResultEntry = EntryId.of(utf8.encode('wrong-result-entry'));
    returnedController.add((
      proposed: wrongId,
      resultEntry: wrongResultEntry,
      result: {'kind': 'refused', 'why': 'not this one'},
    ));

    final outcomeFuture = crux.propose(proposal);

    final writtenBytes = utf8.encode(jsonEncode(proposal));
    final id = EntryId.of(writtenBytes);
    final resultEntry = EntryId.of(utf8.encode('the-matching-result-entry'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
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
    final entries = <Entry>[];
    final sub = LogbookReader('${tmp.path}/logbook.read.sock')
        .subscribe(kinds: {proposedKind})
        .listen((item) {
          if (item is Entry) entries.add(item);
        });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();

    expect(entries, hasLength(1));
    expect(entries.single.previous, rootHash);
    expect(entries.single.body, writtenBytes);

    await returnedController.close();
  });
}
