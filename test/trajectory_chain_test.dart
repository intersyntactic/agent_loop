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
  // Never checked, only well-formed: the service never reads this field
  // back as anything but an opaque hex string.
  final trajectoryUnderTest = client.ObjectId.of(
    Uint8List.fromList('trajectory-under-test'.codeUnits),
  ).hex;

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
      trajectory: trajectoryUnderTest,
      mission: client.ObjectId.of(Uint8List.fromList('mission-a'.codeUnits))
          .hex,
      loopUser: '1001',
      suit: '1002',
    );

    expect(await findTrajectoryRoot(reader, loopUser: '1001'), root);
  });

  test('refuses when no assignment names this loop user', () async {
    await assign(
      trajectory: trajectoryUnderTest,
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
      trajectory: trajectoryUnderTest,
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

  test('a restarted loop appends after its own last entry, not its root; '
      'a chain that was not resumed is still refused', () async {
    final root = await assign(
      trajectory: trajectoryUnderTest,
      mission: client.ObjectId.of(Uint8List.fromList('mission-d'.codeUnits))
          .hex,
      loopUser: uid,
      suit: '1002',
    );
    final writer = LogbookWriter('${tmp.path}/logbook.sock');

    // The first run: two entries after the root.
    final firstRun = TrajectoryChain(writer: writer, kind: turnKind, tip: root);
    await firstRun.append({'shape': 'Note', 'text': 'turn 1'}, const Own());
    final lastOfFirstRun = await firstRun.append({
      'shape': 'Note',
      'text': 'turn 1 post',
    }, const Own());

    // Starting again from the root without resuming is refused, naming the
    // real tip.
    final notResumed = TrajectoryChain(
      writer: writer,
      kind: turnKind,
      tip: root,
    );
    await expectLater(
      notResumed.append({'shape': 'Note', 'text': 'x'}, const Own()),
      throwsA(
        isA<LogbookWriteRefused>().having((e) => e.tip, 'tip', lastOfFirstRun),
      ),
    );

    // The restarted run follows its own last entry, then tracks its own tip.
    final restarted = TrajectoryChain.resumed(
      writer: writer,
      kind: turnKind,
      root: root,
    );
    final turn2 = await restarted.append({
      'shape': 'Note',
      'text': 'turn 2',
    }, const Own());
    final turn2Post = await restarted.append({
      'shape': 'Note',
      'text': 'turn 2 post',
    }, const Own());

    final found = <client.ObjectId>[];
    final sub = followTrajectory(
      reader,
      kind: turnKind,
      chainRoot: root,
    ).listen((e) => found.add(e.$1));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();

    expect(found.skip(2), [turn2, turn2Post]);
    expect(found[1], lastOfFirstRun);
  });

  test('a restarted loop whose first entry repeats an earlier one exactly '
      'still appends after its own last entry', () async {
    // The live case: the system prompt piece is the same bytes after the
    // same root on every turn's first request, so the logbook already holds
    // it and says so before it checks the tip.
    final root = await assign(
      trajectory: trajectoryUnderTest,
      mission: client.ObjectId.of(Uint8List.fromList('mission-f'.codeUnits))
          .hex,
      loopUser: uid,
      suit: '1002',
    );
    final writer = LogbookWriter('${tmp.path}/logbook.sock');
    const systemPrompt = {'shape': 'Note', 'text': 'the system prompt'};

    final firstRun = TrajectoryChain(writer: writer, kind: turnKind, tip: root);
    await firstRun.append(systemPrompt, const Own());
    await firstRun.append({'shape': 'Note', 'text': 'request 1'}, const Own());
    final proposal = await firstRun.append({
      'shape': 'Note',
      'text': 'proposal 1',
    }, const Own());

    final restarted = TrajectoryChain.resumed(
      writer: writer,
      kind: turnKind,
      root: root,
    );
    await restarted.append(systemPrompt, const Own());
    final request2 = await restarted.append({
      'shape': 'Note',
      'text': 'request 2',
    }, const Own());

    final found = <client.ObjectId>[];
    final sub = followTrajectory(
      reader,
      kind: turnKind,
      chainRoot: root,
    ).listen((e) => found.add(e.$1));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();

    expect(found.last, request2);
    expect(found[found.length - 2], proposal);
  });

  test(
    'a restarted loop told its last entry appends straight after it',
    () async {
      final root = await assign(
        trajectory: trajectoryUnderTest,
        mission: client.ObjectId.of(Uint8List.fromList('mission-g'.codeUnits))
            .hex,
        loopUser: uid,
        suit: '1002',
      );
      final writer = LogbookWriter('${tmp.path}/logbook.sock');
      final firstRun = TrajectoryChain(
        writer: writer,
        kind: turnKind,
        tip: root,
      );
      final last = await firstRun.append({
        'shape': 'Note',
        'text': 'turn 1',
      }, const Own());

      final restarted = TrajectoryChain.resumed(
        writer: writer,
        kind: turnKind,
        root: root,
      )..resumeAfter(last);
      expect(restarted.tip, last);
      await restarted.append({'shape': 'Note', 'text': 'turn 2'}, const Own());

      // Once confirmed, a later hint changes nothing.
      restarted.resumeAfter(root);
      expect(restarted.tip, isNot(root));
    },
  );

  test('a resumed chain follows the service\'s tip only until an append is '
      'newly added', () async {
    final root = await assign(
      trajectory: trajectoryUnderTest,
      mission: client.ObjectId.of(Uint8List.fromList('mission-e'.codeUnits))
          .hex,
      loopUser: uid,
      suit: '1002',
    );
    final writer = LogbookWriter('${tmp.path}/logbook.sock');
    final resumed = TrajectoryChain.resumed(
      writer: writer,
      kind: turnKind,
      root: root,
    );
    await resumed.append({'shape': 'Note', 'text': 'mine'}, const Own());

    // Another writer moves the tip on behind this chain's back: after its
    // first append, a resumed chain refuses rather than following it.
    final other = TrajectoryChain(
      writer: writer,
      kind: turnKind,
      tip: resumed.tip,
    );
    await other.append({'shape': 'Note', 'text': 'not mine'}, const Own());

    await expectLater(
      resumed.append({'shape': 'Note', 'text': 'mine again'}, const Own()),
      throwsA(isA<LogbookWriteRefused>()),
    );
  });
}
