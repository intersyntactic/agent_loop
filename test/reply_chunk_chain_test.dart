// Proves ReplyChunkChain against a real JournalService over a real Unix
// socket: the chain's root is an attached root (is_journal 0.9.0) naming
// its parent as the body's first line, enforced by the service itself, not
// a claim in JSON a reader has to trust — a chunk chain only attaches to a
// path the sender actually owns. Later entries chain normally, as bare
// nodes with no envelope.
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
  late int uid;
  final turnKind = Kind.parse('turn')!;
  final chunkKind = Kind.parse('reply-chunk')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_chunk_test_');
    uid = int.parse(Process.runSync('id', ['-u']).stdout.toString().trim());
    final senderTable = SenderTable.parse(
      Uint8List.fromList(
        '$uid turn reply-chunk users-assigned-to-journey-path\nattaching: reply-chunk\n'
            .codeUnits,
      ),
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

  /// Assigns a path to this test's own uid (so it owns the path's chain),
  /// then appends one `turn` entry on it, to use as a chunk chain's parent.
  Future<EntryHash> newOwnedTurn() async {
    final random = EntryHash.of(
      Uint8List.fromList('${DateTime.now().microsecondsSinceEpoch}'.codeUnits),
    );
    final root = await writer.append(
      Kind.parse('users-assigned-to-journey-path')!,
      null,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'journeyPath': random.hex,
            'journey': random.hex,
            'loopUser': '$uid',
            // A path's two users are never the same user; any other number
            // works here, since nothing in this test acts as the suit.
            'suit': '${uid + 1}',
          }),
        ),
      ),
    );
    return writer.append(
      turnKind,
      root,
      Uint8List.fromList(utf8.encode('{"shape":"UserSaid"}')),
    );
  }

  test('the root names its parent as the body\'s first line', () async {
    final parent = await newOwnedTurn();
    final chain = ReplyChunkChain(
      writer: writer,
      kind: chunkKind,
      parent: parent,
    );
    final id = await chain.append({'shape': 'ReplyChunk', 'text': 'hel'});

    expect(chain.tip, id);
    final body = utf8.decode(_lastEntryBody(tmp, service));
    expect(body, '${parent.hex}\n{"shape":"ReplyChunk","text":"hel"}');
  });

  test('a later chunk is a bare node, no envelope', () async {
    final parent = await newOwnedTurn();
    final chain = ReplyChunkChain(
      writer: writer,
      kind: chunkKind,
      parent: parent,
    );
    await chain.append({'shape': 'ReplyChunk', 'text': 'hel'});
    final second = await chain.append({'shape': 'ReplyChunk', 'text': 'lo'});

    expect(chain.tip, second);
    expect(
      utf8.decode(_lastEntryBody(tmp, service)),
      jsonEncode({'shape': 'ReplyChunk', 'text': 'lo'}),
    );
  });

  test('a second chunk follows the first, on its own chain', () async {
    final parent = await newOwnedTurn();
    final chain = ReplyChunkChain(
      writer: writer,
      kind: chunkKind,
      parent: parent,
    );
    final first = await chain.append({'shape': 'ReplyChunk', 'text': 'hel'});
    final second = await chain.append({'shape': 'ReplyChunk', 'text': 'lo'});

    expect(first, isNot(second));
    expect(chain.tip, second);
  });

  test('concurrent appends still follow the true tip, not race it', () async {
    final parent = await newOwnedTurn();
    final chain = ReplyChunkChain(
      writer: writer,
      kind: chunkKind,
      parent: parent,
    );
    final appends = await Future.wait([
      chain.append({'shape': 'ReplyChunk', 'text': 'a'}),
      chain.append({'shape': 'ReplyChunk', 'text': 'b'}),
      chain.append({'shape': 'ReplyChunk', 'text': 'c'}),
    ]);

    expect(appends.toSet().length, 3);
    expect(chain.tip, appends.last);
  });

  test('the service refuses a root naming an unknown parent', () async {
    final unknown = EntryHash.of(Uint8List.fromList('never written'.codeUnits));
    final chain = ReplyChunkChain(
      writer: writer,
      kind: chunkKind,
      parent: unknown,
    );

    expect(
      () => chain.append({'shape': 'ReplyChunk', 'text': 'hel'}),
      throwsA(
        isA<JournalWriteRefused>().having(
          (e) => e.why,
          'why',
          contains('unknown'),
        ),
      ),
    );
  });

  test('the service refuses a root naming a parent on no path', () async {
    final unowned = await writer.append(
      turnKind,
      null,
      Uint8List.fromList(utf8.encode('{"shape":"UserSaid"}')),
    );
    final chain = ReplyChunkChain(
      writer: writer,
      kind: chunkKind,
      parent: unowned,
    );

    expect(
      () => chain.append({'shape': 'ReplyChunk', 'text': 'hel'}),
      throwsA(
        isA<JournalWriteRefused>().having(
          (e) => e.why,
          'why',
          contains('parent-unowned'),
        ),
      ),
    );
  });
}

/// The last entry's body: its object's bytes with the `<kind>\n<previous>\n`
/// header stripped.
Uint8List _lastEntryBody(Directory tmp, JournalService service) {
  final entries = File('${tmp.path}/journal/entries').readAsBytesSync();
  final last = JournalEntry.parse(
    entries.sublist(entries.length - JournalEntry.length),
  )!;
  final object = service.journal.get(last.object)!;
  return _stripHeader(object);
}

Uint8List _stripHeader(Uint8List object) {
  final first = object.indexOf(0x0a);
  final second = object.indexOf(0x0a, first + 1);
  return Uint8List.sublistView(object, second + 1);
}
