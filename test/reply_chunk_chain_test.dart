// Proves ReplyChunkChain against a real JournalService over a real Unix
// socket: a chunk appended becomes an entry chained after the one before
// it, on its own chain, separate from any JourneyPathChain's kind, and
// carries no envelope — the raw node is what's recorded.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_journal/is_journal.dart';
import 'package:is_journal/service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late JournalService service;
  late JournalWriter writer;
  final chunkKind = Kind.parse('chunk')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_chunk_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList('$uid chunk\n'.codeUnits),
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

  test('a chunk is its own entry, with no envelope', () async {
    final chain = ReplyChunkChain(writer: writer, kind: chunkKind);
    final id = await chain.append({'shape': 'ReplyChunk', 'text': 'hel'});

    expect(chain.tip, id);

    final entries = File('${tmp.path}/journal/entries').readAsBytesSync();
    final last = JournalEntry.parse(
      entries.sublist(entries.length - JournalEntry.length),
    )!;
    final object = service.journal.get(last.object)!;
    final node = jsonDecodeNode(_stripHeader(object));

    expect(node, {'shape': 'ReplyChunk', 'text': 'hel'});
  });

  test('a second chunk follows the first, on its own chain', () async {
    final chain = ReplyChunkChain(writer: writer, kind: chunkKind);
    final first = await chain.append({'shape': 'ReplyChunk', 'text': 'hel'});
    final second = await chain.append({'shape': 'ReplyChunk', 'text': 'lo'});

    expect(first, isNot(second));
    expect(chain.tip, second);
  });

  test('concurrent appends still follow the true tip, not race it', () async {
    final chain = ReplyChunkChain(writer: writer, kind: chunkKind);
    final appends = await Future.wait([
      chain.append({'shape': 'ReplyChunk', 'text': 'a'}),
      chain.append({'shape': 'ReplyChunk', 'text': 'b'}),
      chain.append({'shape': 'ReplyChunk', 'text': 'c'}),
    ]);

    expect(appends.toSet().length, 3);
    expect(chain.tip, appends.last);
  });
}

/// The bytes after an entry object's own `<kind>\n<follows>\n` header,
/// decoded as JSON: a raw node, with no turn envelope around it.
Object? jsonDecodeNode(Uint8List bytes) => jsonDecode(utf8.decode(bytes));

Uint8List _stripHeader(Uint8List object) {
  final first = object.indexOf(0x0a);
  final second = object.indexOf(0x0a, first + 1);
  return Uint8List.sublistView(object, second + 1);
}
