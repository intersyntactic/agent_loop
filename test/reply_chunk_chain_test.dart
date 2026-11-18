// Proves ReplyChunkChain against a real LogbookService over a real Unix
// socket: the chain's root is an attached root naming its parent as the
// body's first line, enforced by the service itself, not a claim in JSON a
// reader has to trust — a chunk chain only attaches to a trajectory the
// sender actually owns. Later entries chain normally, as bare nodes with no
// envelope.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';
import 'package:is_logbook_client/is_logbook_client.dart' show LogbookReader;
import 'package:is_logbook_client/is_logbook_client.dart' as client;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late LogbookService service;
  late client.LogbookWriter rawWriter;
  late LogbookWriter writer;
  late LogbookReader reader;
  late int uid;
  final turnKind = Kind.parse('turn')!;
  final chunkKind = Kind.parse('reply-chunk')!;
  // Never checked, only well-formed: the service never reads this field
  // back as anything but an opaque hex string.
  final trajectoryUnderTest = client.ObjectId.of(
    Uint8List.fromList('trajectory-under-test'.codeUnits),
  ).hex;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_chunk_test_');
    uid = int.parse(Process.runSync('id', ['-u']).stdout.toString().trim());
    final senderTable = SenderTable.parse(
      Uint8List.fromList(
        '$uid turn reply-chunk users-assigned-to-trajectory\n'
                'attaching: reply-chunk\n'
            .codeUnits,
      ),
    );
    service = await LogbookService.start(
      Logbook.open(Directory('${tmp.path}/logbook'))!,
      senderTable,
      File('${tmp.path}/logbook.sock'),
      readSocket: File('${tmp.path}/logbook.read.sock'),
    );
    rawWriter = client.LogbookWriter('${tmp.path}/logbook.sock');
    writer = LogbookWriter('${tmp.path}/logbook.sock');
    reader = LogbookReader('${tmp.path}/logbook.read.sock');
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  /// Assigns a trajectory to this test's own uid (so it owns the
  /// trajectory's chain), then appends one `turn` entry on it, to use as a
  /// chunk chain's parent.
  Future<client.ObjectId> newOwnedTurn() async {
    final random = client.ObjectId.of(
      Uint8List.fromList('${DateTime.now().microsecondsSinceEpoch}'.codeUnits),
    );
    final assigned = await rawWriter.write(
      Kind.usersAssignedToTrajectory,
      utf8.encode(
        jsonEncode({
          'trajectory': trajectoryUnderTest,
          'mission': random.hex,
          'loopUser': '$uid',
          // A trajectory's two users are never the same user; any other
          // number works here, since nothing in this test acts as the suit.
          'suit': '${uid + 1}',
        }),
      ),
    );
    final root = (assigned as client.Written).entry;
    final turn = await rawWriter.write(
      turnKind,
      utf8.encode('{"shape":"UserSaid"}'),
      previous: root,
    );
    return (turn as client.Written).entry;
  }

  /// [id]'s recorded body, read back through the real read socket.
  Future<Uint8List> bodyOf(client.ObjectId id) async {
    final got = await reader.get(id);
    return (got as client.GotEntry).entry.body;
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
    final body = utf8.decode(await bodyOf(id));
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
      utf8.decode(await bodyOf(second)),
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
    final unknown = client.ObjectId.of(
      Uint8List.fromList('never written'.codeUnits),
    );
    final chain = ReplyChunkChain(
      writer: writer,
      kind: chunkKind,
      parent: unknown,
    );

    expect(
      () => chain.append({'shape': 'ReplyChunk', 'text': 'hel'}),
      throwsA(
        isA<LogbookWriteRefused>().having(
          (e) => e.why,
          'why',
          contains('unknown'),
        ),
      ),
    );
  });

  test('the service refuses a root naming a parent on no trajectory', () async {
    final unowned = await rawWriter.write(
      turnKind,
      utf8.encode('{"shape":"UserSaid"}'),
    );
    final chain = ReplyChunkChain(
      writer: writer,
      kind: chunkKind,
      parent: (unowned as client.Written).entry,
    );

    expect(
      () => chain.append({'shape': 'ReplyChunk', 'text': 'hel'}),
      throwsA(
        isA<LogbookWriteRefused>().having(
          (e) => e.why,
          'why',
          contains('parent-unowned'),
        ),
      ),
    );
  });
}
