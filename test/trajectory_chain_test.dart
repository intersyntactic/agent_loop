// Proves findTrajectoryRoot, followTrajectory and TrajectoryChain against a
// real is_logbook LogbookService over real Unix sockets.
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
  late LogbookReader reader;
  late String uid;
  final turnKind = Kind.parse('turn')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_trajectory_test_');
    uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList('$uid turn users-assigned-to-trajectory\n'.codeUnits),
    );
    service = await LogbookService.start(
      Logbook.open(Directory('${tmp.path}/logbook'))!,
      senderTable,
      File('${tmp.path}/logbook.sock'),
      readSocket: File('${tmp.path}/logbook.read.sock'),
    );
    rawWriter = client.LogbookWriter('${tmp.path}/logbook.sock');
    reader = LogbookReader('${tmp.path}/logbook.read.sock');
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  Future<client.ObjectId> assign({
    required String trajectory,
    required String mission,
    required String loopUser,
    required String suit,
  }) async {
    final result = await rawWriter.write(
      Kind.usersAssignedToTrajectory,
      utf8.encode(
        jsonEncode({
          'trajectory': trajectory,
          'mission': mission,
          'loopUser': loopUser,
          'suit': suit,
        }),
      ),
    );
    return (result as client.Written).entry;
  }

  test('finds the latest assignment naming this loop user', () async {
    final root = await assign(
      trajectory: EntryHash.origin.hex,
      mission: client.ObjectId.of(Uint8List.fromList('mission-a'.codeUnits))
          .hex,
      loopUser: '1001',
      suit: '1002',
    );

    expect(await findTrajectoryRoot(reader, loopUser: '1001'), root);
  });

  test('refuses when no assignment names this loop user', () async {
    await assign(
      trajectory: EntryHash.origin.hex,
      mission: client.ObjectId.of(Uint8List.fromList('mission-b'.codeUnits))
          .hex,
      loopUser: '1001',
      suit: '1002',
    );

    await expectLater(
      findTrajectoryRoot(reader, loopUser: 'nobody'),
      throwsA(isA<NoTrajectoryAssigned>()),
    );
  });

  test('follows only this trajectory\'s own turns, live, with their '
      'hashes', () async {
    final root = await assign(
      trajectory: EntryHash.origin.hex,
      mission: client.ObjectId.of(Uint8List.fromList('mission-c'.codeUnits))
          .hex,
      loopUser: uid,
      suit: '1002',
    );

    // An unrelated turn entry, rooting a chain of its own (real ownership
    // rules only gate an entry naming a previous on an owned chain, so this
    // needs no second uid to construct): must never appear in the first
    // trajectory's feed even though it shares the same turn kind.
    await rawWriter.write(
      turnKind,
      utf8.encode(jsonEncode({'shape': 'Note', 'text': 'other'})),
    );

    final chain = TrajectoryChain(
      writer: LogbookWriter('${tmp.path}/logbook.sock'),
      kind: turnKind,
      tip: root,
    );
    final first = await chain.append({
      'shape': 'UserSaid',
      'text': 'hi',
    }, const Own());
    final second = await chain.append({
      'shape': 'ReplyText',
      'text': 'hello',
    }, const Own());

    final found = <(client.ObjectId, TurnEnvelope)>[];
    final sub = followTrajectory(
      reader,
      kind: turnKind,
      chainRoot: root,
    ).listen(found.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();

    expect(found, hasLength(2));
    expect(found[0].$1, first);
    expect(found[0].$2.node['text'], 'hi');
    expect(found[1].$1, second);
    expect(found[1].$2.node['text'], 'hello');
  });
}
