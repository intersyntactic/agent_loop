// Proves JourneyPathChain and TurnEnvelope against a real JournalService
// over a real Unix socket, with no Teams module in the picture: a node
// appended becomes an entry whose hash is its TurnId, chained after the
// one before it, and its envelope round-trips through decode.
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_journal/is_journal.dart';
import 'package:is_journal/service.dart';
import 'package:is_shapes/is_shapes.dart' show TurnId;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late JournalService service;
  late JournalWriter writer;
  final kind = Kind.parse('turn')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_chain_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList('$uid turn\n'.codeUnits),
    );
    service = await JournalService.start(
      Journal.open(Directory('${tmp.path}/journal'))!,
      senderTable,
      File('${tmp.path}/journal.sock'),
    );
    writer = JournalWriter('${tmp.path}/journal.sock');
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  test('a turn\'s id is its journal entry hash', () async {
    final chain = JourneyPathChain(writer: writer, kind: kind);
    final id = await chain.append({
      'shape': 'Note',
      'text': 'hello',
    }, const Own());

    expect(chain.lastTurn, id);
    expect(chain.tip, isNotNull);
    expect(TurnId.parse(chain.tip!.hex), id);
  });

  test('a second append follows the first', () async {
    final chain = JourneyPathChain(writer: writer, kind: kind);
    final first = await chain.append({
      'shape': 'Note',
      'text': 'a',
    }, const Own());
    final second = await chain.append({
      'shape': 'Note',
      'text': 'b',
    }, const Own());

    expect(first, isNot(second));
    expect(chain.lastTurn, second);
  });

  test('an envelope round-trips its node and provenance', () async {
    final admitted = EntryHash.of(Uint8List.fromList('admitted'.codeUnits));
    final chain = JourneyPathChain(writer: writer, kind: kind);
    await chain.append({'shape': 'Note', 'text': 'c'}, FromAdmission(admitted));

    // No read socket in this stage: read the object straight off disk
    // instead, through the journal this service itself writes.
    final entries = File('${tmp.path}/journal/entries').readAsBytesSync();
    final last = JournalEntry.parse(
      entries.sublist(entries.length - JournalEntry.length),
    )!;
    final object = service.journal.get(last.object)!;
    final envelope = TurnEnvelope.decode(_stripHeader(object));

    expect(envelope.node, {'shape': 'Note', 'text': 'c'});
    expect(envelope.provenance, isA<FromAdmission>());
    expect((envelope.provenance as FromAdmission).admitted, admitted);
  });
}

/// The bytes after an entry object's own `<kind>\n<previous>\n` header.
Uint8List _stripHeader(Uint8List object) {
  final first = object.indexOf(0x0a);
  final second = object.indexOf(0x0a, first + 1);
  return Uint8List.sublistView(object, second + 1);
}
