// Proves rebuildChatJourneyPaths against a real JournalService: two
// chats written before a "restart", a fresh ChatJourneyPaths rebuilt
// from the record alone, able to carry on each chat's chain and route a
// reply through its translator exactly as the live process could.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_journal/is_journal.dart';
import 'package:is_journal/service.dart';
import 'package:is_shapes/is_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late JournalService service;
  late JournalWriter writer;
  late JournalReader reader;
  final turnKind = Kind.parse('turn')!;
  final witnessedKind = Kind.parse('witnessed')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_rebuild_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList('$uid turn witnessed\n'.codeUnits),
    );
    service = await JournalService.start(
      Journal.open(Directory('${tmp.path}/journal'))!,
      senderTable,
      File('${tmp.path}/journal.sock'),
      readSocket: File('${tmp.path}/journal.read.sock'),
    );
    writer = JournalWriter('${tmp.path}/journal.sock');
    reader = JournalReader('${tmp.path}/journal.read.sock');
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  TeamsMessage messageIn(String chat, String id, String text) => TeamsMessage(
    conversation: chat,
    id: id,
    serviceUrl: Uri.parse('https://smba.example.com/amer'),
    tenant: 'tenant-a',
    fromAadObjectId: 'user-1',
    text: text,
  );

  EntryHash fakeArrival(String seed) =>
      EntryHash.of(Uint8List.fromList(utf8.encode(seed)));

  test(
    'rebuilds two chats\' chains and translators, and resumes them',
    () async {
      final before = ChatJourneyPaths(writer: writer, kind: turnKind);
      final turnA1 = await ingestIntoChat(
        messageIn('chat-a', 'msg-1', 'hello a'),
        paths: before,
        arrival: fakeArrival('a-1'),
      );
      await ingestIntoChat(
        messageIn('chat-b', 'msg-1', 'hello b'),
        paths: before,
        arrival: fakeArrival('b-1'),
      );
      final tipBeforeA = before.forChat('chat-a').chain.tip;
      final tipBeforeB = before.forChat('chat-b').chain.tip;

      // "Restart": a fresh ChatJourneyPaths, with nothing but the record.
      final after = ChatJourneyPaths(writer: writer, kind: turnKind);
      final rebuild = await rebuildChatJourneyPaths(
        reader,
        after,
        turnKind: turnKind,
        witnessedKind: witnessedKind,
      );

      expect(rebuild.unhandledArrivals, isEmpty);
      expect(after.forChat('chat-a').chain.tip, tipBeforeA);
      expect(after.forChat('chat-b').chain.tip, tipBeforeB);

      // The rebuilt translator can still route a reply to chat-a's turn.
      final reply = ReplyText(
        by: ActorId.parse('agent:test')!,
        answers: turnA1!,
        text: 'hi a',
      );
      final post = after.forChat('chat-a').translator.answer(reply);
      expect(post, isNotNull);
      expect(post!.conversation, 'chat-a');

      // A second message in chat-a, after the rebuild, follows on from
      // its recovered tip rather than starting a new chain.
      final turnA2 = await ingestIntoChat(
        messageIn('chat-a', 'msg-2', 'second'),
        paths: after,
        arrival: fakeArrival('a-2'),
      );
      expect(turnA2, isNot(turnA1));
    },
  );

  test('names a witnessed arrival with no turn as unhandled', () async {
    // Witnessed, but never translated into a turn (the loop crashed
    // before it could, or there was nothing to say).
    final stray = await writer.append(
      witnessedKind,
      null,
      Uint8List.fromList(utf8.encode('stray')),
    );

    final paths = ChatJourneyPaths(writer: writer, kind: turnKind);
    final rebuild = await rebuildChatJourneyPaths(
      reader,
      paths,
      turnKind: turnKind,
      witnessedKind: witnessedKind,
    );

    expect(rebuild.unhandledArrivals.map((a) => a.hash), [stray]);
  });
}
