// Proves each Teams chat gets its own journey path: its own chain, its
// own TeamsTranslator, and a reply routed to the chat it answers in —
// against a real JournalService over a real Unix socket.
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
  late ChatJourneyPaths paths;
  final kind = Kind.parse('turn')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_chats_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList('$uid turn\n'.codeUnits),
    );
    service = await JournalService.start(
      Journal.open(Directory('${tmp.path}/journal'))!,
      senderTable,
      File('${tmp.path}/journal.sock'),
    );
    paths = ChatJourneyPaths(
      writer: JournalWriter('${tmp.path}/journal.sock'),
      kind: kind,
    );
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

  test('two chats get two chains, each starting its own', () async {
    final firstChatTurn = await ingestIntoChat(
      messageIn('chat-a', 'msg-1', 'hello a'),
      paths: paths,
      arrival: fakeArrival('a-1'),
    );
    final secondChatTurn = await ingestIntoChat(
      messageIn('chat-b', 'msg-1', 'hello b'),
      paths: paths,
      arrival: fakeArrival('b-1'),
    );

    expect(firstChatTurn, isNotNull);
    expect(secondChatTurn, isNotNull);
    // Each chat wrote its own TeamsConversation then its own UserSaid, and
    // neither chain follows the other's: two roots, not one chain of four.
    expect(
      paths.forChat('chat-a').chain.tip,
      isNot(paths.forChat('chat-b').chain.tip),
    );

    final replyToA = ReplyText(
      by: ActorId.parse('agent:test')!,
      answers: firstChatTurn!,
      text: 'hi a',
    );
    final postToA = paths.forChat('chat-a').translator.answer(replyToA);
    expect(postToA, isNotNull);
    expect(postToA!.conversation, 'chat-a');

    // chat-b's translator never saw chat-a's turn.
    expect(paths.forChat('chat-b').translator.answer(replyToA), isNull);
  });

  test('a second message in the same chat reuses its chain', () async {
    await ingestIntoChat(
      messageIn('chat-a', 'msg-1', 'first'),
      paths: paths,
      arrival: fakeArrival('a-1'),
    );
    final before = paths.forChat('chat-a').chain.tip;
    await ingestIntoChat(
      messageIn('chat-a', 'msg-2', 'second'),
      paths: paths,
      arrival: fakeArrival('a-2'),
    );
    final after = paths.forChat('chat-a').chain.tip;

    expect(before, isNotNull);
    expect(after, isNot(before));
  });
}
