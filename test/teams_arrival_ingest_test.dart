// Proves ingestTeamsMessage against a real JournalService over a real
// Unix socket, not a reimplementation of its wire protocol: a Teams
// message in, a TeamsConversation then a UserSaid out, chained and
// readable back from disk, and a reply routed back to where it was said.
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
  final kind = Kind.parse('turn')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      // The test process' own uid writes `turn`.
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

  test(
    'ingests a Teams message as a TeamsConversation then a UserSaid',
    () async {
      final chain = JourneyPathChain(writer: writer, kind: kind);
      final translator = TeamsTranslator();
      final message = TeamsMessage(
        conversation: 'conv-1',
        id: 'msg-1',
        serviceUrl: Uri.parse('https://smba.example.com/amer'),
        tenant: 'Tenant-A',
        fromAadObjectId: 'User-1',
        text: 'hello <at>Bot</at>',
      );

      final said = await ingestTeamsMessage(
        message,
        translator: translator,
        chain: chain,
        arrival: fakeArrival('msg-1'),
      );

      expect(said, isNotNull);
      expect(chain.lastTurn, said);
      // The service's own `started` entry, then the TeamsConversation, then
      // the UserSaid.
      expect(entryCount(service), 3);

      final reply = ReplyText(
        by: ActorId.parse('agent:test')!,
        answers: said!,
        text: 'hi there',
      );
      final post = translator.answer(reply);
      expect(post, isNotNull);
      expect(post!.conversation, 'conv-1');
      expect(post.replyToId, 'msg-1');
      expect(post.serviceUrl, Uri.parse('https://smba.example.com/amer'));
    },
  );

  test('two messages chain, each following the last', () async {
    final chain = JourneyPathChain(writer: writer, kind: kind);
    final translator = TeamsTranslator();
    final first = await ingestTeamsMessage(
      TeamsMessage(
        conversation: 'conv-1',
        id: 'msg-1',
        serviceUrl: Uri.parse('https://smba.example.com/amer'),
        tenant: 'tenant-a',
        fromAadObjectId: 'user-1',
        text: 'first',
      ),
      translator: translator,
      chain: chain,
      arrival: fakeArrival('msg-1'),
    );
    final second = await ingestTeamsMessage(
      TeamsMessage(
        conversation: 'conv-1',
        id: 'msg-2',
        serviceUrl: Uri.parse('https://smba.example.com/amer'),
        tenant: 'tenant-a',
        fromAadObjectId: 'user-1',
        text: 'second',
      ),
      translator: translator,
      chain: chain,
      arrival: fakeArrival('msg-2'),
    );

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first, isNot(second));
    // `started`, the TeamsConversation, the first UserSaid, and the
    // second — no second TeamsConversation, since the chat was already
    // joined.
    expect(entryCount(service), 4);
  });
}

/// The journal's own count of intact entries ([Journal.check]), as proof
/// the entries this test wrote are really chained and really there.
int entryCount(JournalService service) {
  final check = service.journal.check();
  return check is Intact ? check.count : 0;
}

/// A stand-in for the arrival this test never really witnesses: the hash
/// a real `witnessed` entry would have, were [seed] its bytes.
EntryHash fakeArrival(String seed) =>
    EntryHash.of(Uint8List.fromList(utf8.encode(seed)));
