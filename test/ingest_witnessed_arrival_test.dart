// Proves the one seam a witnessed arrival's bytes become a turn
// through: WitnessedArrival.decode reads is_airlock's own
// {at, source, bytes} format, and ingestWitnessedArrival routes a parsed
// TeamsMessage into ChatJourneyPaths — against a real JournalService, so
// the entry hash it's given really is one a journal would hand back.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_journal/is_journal.dart';
import 'package:is_journal/service.dart';
import 'package:is_teams_module/is_teams_module.dart';
import 'package:test/test.dart';

/// A witnessed entry's body, exactly as is_airlock's Witness.witness
/// writes it.
Uint8List witnessedBody(String source, Uint8List activityBytes) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'at': DateTime.utc(2026, 11, 15).toIso8601String(),
          'source': source,
          'bytes': base64Encode(activityBytes),
        }),
      ),
    );

void main() {
  test('WitnessedArrival.decode reads is_airlock\'s own format', () {
    final activity = Uint8List.fromList(utf8.encode('{"type":"message"}'));
    final witnessed = WitnessedArrival.decode(witnessedBody('teams', activity));

    expect(witnessed.source.toString(), 'teams');
    expect(witnessed.bytes, activity);
  });

  group('ingestWitnessedArrival', () {
    late Directory tmp;
    late JournalService service;
    late ChatJourneyPaths paths;
    final kind = Kind.parse('turn')!;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('agent_loop_ingest_test_');
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

    final message = TeamsMessage(
      conversation: 'chat-a',
      id: 'msg-1',
      serviceUrl: Uri.parse('https://smba.example.com/amer'),
      tenant: 'tenant-a',
      fromAadObjectId: 'user-1',
      text: 'hello',
    );

    EntryHash fakeArrival(String seed) =>
        EntryHash.of(Uint8List.fromList(utf8.encode(seed)));

    late SeenTeamsMessages seen;
    setUp(() => seen = SeenTeamsMessages());

    test('routes a parsed TeamsMessage into its chat', () async {
      final activity = Uint8List.fromList(utf8.encode('the raw activity'));
      final turn = await ingestWitnessedArrival(
        fakeArrival('a-1'),
        witnessedBody('teams', activity),
        parse: (bytes) =>
            utf8.decode(bytes) == 'the raw activity' ? message : null,
        paths: paths,
        seen: seen,
      );

      expect(turn, isNotNull);
      expect(paths.forChat('chat-a').chain.tip, isNotNull);
    });

    test('is null for a source that is not teams', () async {
      final activity = Uint8List.fromList(utf8.encode('x'));
      final turn = await ingestWitnessedArrival(
        fakeArrival('a-1'),
        witnessedBody('slack', activity),
        parse: (bytes) => message,
        paths: paths,
        seen: seen,
      );

      expect(turn, isNull);
    });

    test('is null when parse finds nothing to ingest', () async {
      final activity = Uint8List.fromList(utf8.encode('x'));
      final turn = await ingestWitnessedArrival(
        fakeArrival('a-1'),
        witnessedBody('teams', activity),
        parse: (bytes) => null,
        paths: paths,
        seen: seen,
      );

      expect(turn, isNull);
    });

    test('the same activity witnessed twice is one turn, not two', () async {
      final activity = Uint8List.fromList(utf8.encode('the raw activity'));
      final body = witnessedBody('teams', activity);
      ParseTeamsActivity parse = (bytes) =>
          utf8.decode(bytes) == 'the raw activity' ? message : null;

      final first = await ingestWitnessedArrival(
        fakeArrival('a-1'),
        body,
        parse: parse,
        paths: paths,
        seen: seen,
      );
      // Witnessed again: a relay restart's retry, or a retry after a
      // partial witness, carries a different arrival hash but the same
      // activity.
      final second = await ingestWitnessedArrival(
        fakeArrival('a-1-retry'),
        body,
        parse: parse,
        paths: paths,
        seen: seen,
      );

      expect(first, isNotNull);
      expect(second, isNull);
    });

    test(
      'the same activity id in two different chats gives two turns',
      () async {
        // Teams activity ids are unique only within a conversation
        // (teams-module-e2), so the same id in chat-a and chat-b is two
        // different messages, not a retry of one.
        TeamsMessage messageIn(String chat) => TeamsMessage(
          conversation: chat,
          id: 'msg-1',
          serviceUrl: Uri.parse('https://smba.example.com/amer'),
          tenant: 'tenant-a',
          fromAadObjectId: 'user-1',
          text: 'hello from $chat',
        );

        final inA = await ingestWitnessedArrival(
          fakeArrival('a-1'),
          witnessedBody('teams', Uint8List.fromList(utf8.encode('a'))),
          parse: (bytes) => messageIn('chat-a'),
          paths: paths,
          seen: seen,
        );
        final inB = await ingestWitnessedArrival(
          fakeArrival('b-1'),
          witnessedBody('teams', Uint8List.fromList(utf8.encode('b'))),
          parse: (bytes) => messageIn('chat-b'),
          paths: paths,
          seen: seen,
        );

        expect(inA, isNotNull);
        expect(inB, isNotNull);
        expect(paths.forChat('chat-a').chain.tip, isNotNull);
        expect(paths.forChat('chat-b').chain.tip, isNotNull);
      },
    );

    test('a real activity parses through teamsWitnessedEvent', () async {
      final activity = utf8.encode(
        jsonEncode({
          'type': 'message',
          'id': 'msg-1',
          'serviceUrl': 'https://smba.example.com/amer',
          'conversation': {'id': 'chat-a', 'tenantId': 'tenant-a'},
          'from': {'id': '29:user1', 'aadObjectId': 'user-1'},
          'recipient': {'id': '28:bot'},
          'text': 'hello from a real activity',
        }),
      );
      final turn = await ingestWitnessedArrival(
        fakeArrival('a-1'),
        witnessedBody('teams', Uint8List.fromList(activity)),
        parse: teamsWitnessedEvent,
        paths: paths,
        seen: seen,
      );

      expect(turn, isNotNull);
      expect(paths.forChat('chat-a').chain.tip, isNotNull);
    });
  });
}
