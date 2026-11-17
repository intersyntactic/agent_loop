// Proves TrajectoryCrux against a real LogbookService for the write side
// (the `proposed` entry it writes), and a fake `returned` stream for the
// match-by-EntryId-of-raw-bytes rule airlock-api-04 confirmed directly
// (2026-11-18): not the EntryHash a write's `ok` gives back, which depends
// on chain position and so would never match.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart' show ReturnedProposal;
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
  final proposedKind = Kind.parse('proposed')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_crux_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList('$uid turn proposed\n'.codeUnits),
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

    final returnedController = StreamController<ReturnedProposal>();
    final crux = TrajectoryCrux(
      chain: chain,
      returned: returnedController.stream,
    );

    final proposal = {'place': 1, 'program': 'model', 'input': 'x'};

    // A returned entry for a DIFFERENT proposal, which must be ignored,
    // then the matching one.
    final wrongId = EntryId.of(utf8.encode(jsonEncode({'other': true})));
    returnedController.add(
      ReturnedProposal.fromJson({
        'proposed': wrongId.hex,
        'outcome': {'kind': 'refused', 'why': 'not this one'},
      }),
    );

    final outcomeFuture = crux.propose(proposal);

    final writtenBytes = utf8.encode(jsonEncode(proposal));
    final id = EntryId.of(writtenBytes);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    returnedController.add(
      ReturnedProposal.fromJson({
        'proposed': id.hex,
        'outcome': {'kind': 'ran', 'output': 'ok'},
      }),
    );

    final outcome = await outcomeFuture;
    expect(outcome, {'kind': 'ran', 'output': 'ok'});

    // The proposed entry really landed on the chain, after root.
    final entries = <Entry>[];
    final sub = LogbookReader('${tmp.path}/logbook.read.sock')
        .subscribe(kinds: {proposedKind})
        .listen((item) {
          if (item is Entry) entries.add(item);
        });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    unawaited(sub.cancel());

    expect(entries, hasLength(1));
    expect(entries.single.previous, rootHash);
    expect(entries.single.body, writtenBytes);

    await returnedController.close();
  });
}
