// Proves turnsUpTo and renderRequestBody against a real JournalService over
// a real Unix socket: a chain of UserSaid/ReplyText turns reads back in
// order and flattens into one plain-text body.
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_journal/is_journal.dart';
import 'package:is_journal/service.dart';
import 'package:is_shapes/is_shapes.dart' show ActorId;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late JournalService service;
  late JournalWriter writer;
  late JournalReader reader;
  late JourneyPathChain chain;
  final kind = Kind.parse('turn')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_render_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList('$uid turn\n'.codeUnits),
    );
    service = await JournalService.start(
      Journal.open(Directory('${tmp.path}/journal'))!,
      senderTable,
      File('${tmp.path}/journal.sock'),
      readSocket: File('${tmp.path}/journal.read.sock'),
    );
    writer = JournalWriter('${tmp.path}/journal.sock');
    reader = JournalReader('${tmp.path}/journal.read.sock');
    chain = JourneyPathChain(writer: writer, kind: kind);
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  test('flattens a chain of UserSaid/ReplyText turns into one plain-text '
      'body, oldest first', () async {
    final user = ActorId.parse('teams:u1')!;
    final agent = ActorId.parse('agent:a1')!;

    await chain.append(
      UserSaid(
        author: user,
        source: SourceMessageId.parse('m1')!,
        text: 'hey are you there',
      ).toJson().asUncheckedMap(),
      const Own(),
    );
    final tip = await chain.append({
      'shape': 'ReplyText',
      'by': agent.value,
      'answers': chain.lastTurn!.hex,
      'text': 'yep, here',
    }, const Own());

    final turns = await turnsUpTo(
      reader,
      turnKind: kind,
      tip: EntryHash.parse(tip.hex)!,
    );

    expect(turns, hasLength(2));
    expect(
      renderRequestBody(turns),
      'User: hey are you there\nAgent: yep, here',
    );
  });

  test('refuses a tip no backlog names', () async {
    final unknown = EntryHash.of(Uint8List.fromList('nothing'.codeUnits));
    await expectLater(
      turnsUpTo(reader, turnKind: kind, tip: unknown),
      throwsA(isA<JournalReadRefused>()),
    );
  });
}
