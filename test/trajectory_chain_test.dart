// Proves findTrajectoryRoot and TrajectoryChain against a real is_logbook
// LogbookService over real Unix sockets.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';
import 'package:is_logbook_client/is_logbook_client.dart'
    show CaughtUp, Entry, LogbookReader;
import 'package:is_logbook_client/is_logbook_client.dart' as client;
import 'package:test/test.dart';

import 'loop_sender_table.dart';

const _noteKind = KindTheLoopWrites.modelRequestPiece;

void main() {
  late Directory tmp;
  late LogbookService service;
  late client.LogbookWriter rawWriter;
  late LogbookReader reader;
  late String uid;
  // Never checked, only well-formed: the service never reads this field
  // back as anything but an opaque hex string.
  final trajectoryUnderTest = client.ObjectId.of(
    Uint8List.fromList('trajectory-under-test'.codeUnits),
  ).hex;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_trajectory_test_');
    uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    service = await LogbookService.start(
      Logbook.open(Directory('${tmp.path}/logbook'))!,
      loopSenderTable(uid, standIns: ['users-assigned-to-trajectory']),
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

  Future<client.ObjectId> note(TrajectoryChain chain, String text) =>
      chain.appendEntry(_noteKind, utf8.encode(text));

  // Every note on the chain descending from [root], in logbook order.
  Future<List<client.ObjectId>> chainFrom(client.ObjectId root) async {
    final onChain = <client.ObjectId>{root};
    final found = <client.ObjectId>[];
    await for (final item in reader.subscribe(kinds: {_noteKind.kind})) {
      switch (item) {
        case Entry(:final id, :final previous?) when onChain.contains(previous):
          onChain.add(id);
          found.add(id);
        case Entry():
          continue;
        case CaughtUp():
          return found;
      }
    }
    return found;
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
    final firstRun = TrajectoryChain(writer: writer, tip: root);
    await note(firstRun, 'step 1');
    final lastOfFirstRun = await note(firstRun, 'step 1 post');

    // Starting again from the root without resuming is refused, naming the
    // real tip.
    final notResumed = TrajectoryChain(writer: writer, tip: root);
    await expectLater(
      note(notResumed, 'x'),
      throwsA(
        isA<LogbookWriteRefused>().having((e) => e.tip, 'tip', lastOfFirstRun),
      ),
    );

    // The restarted run follows its own last entry, then tracks its own tip.
    final restarted = TrajectoryChain.resumed(writer: writer, root: root);
    final step2 = await note(restarted, 'step 2');
    final step2Post = await note(restarted, 'step 2 post');

    final found = await chainFrom(root);
    expect(found.skip(2), [step2, step2Post]);
    expect(found[1], lastOfFirstRun);
  });

  test('a restarted loop whose first entry repeats an earlier one exactly '
      'still appends after its own last entry', () async {
    // The live case: the system prompt piece is the same bytes after the
    // same root on every first request, so the logbook already holds it and
    // says so before it checks the tip.
    final root = await assign(
      trajectory: trajectoryUnderTest,
      mission: client.ObjectId.of(Uint8List.fromList('mission-f'.codeUnits))
          .hex,
      loopUser: uid,
      suit: '1002',
    );
    final writer = LogbookWriter('${tmp.path}/logbook.sock');
    const systemPrompt = 'the system prompt';

    final firstRun = TrajectoryChain(writer: writer, tip: root);
    await note(firstRun, systemPrompt);
    await note(firstRun, 'request 1');
    final proposal = await note(firstRun, 'proposal 1');

    final restarted = TrajectoryChain.resumed(writer: writer, root: root);
    await note(restarted, systemPrompt);
    final request2 = await note(restarted, 'request 2');

    final found = await chainFrom(root);
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
      final firstRun = TrajectoryChain(writer: writer, tip: root);
      final last = await note(firstRun, 'step 1');

      final restarted = TrajectoryChain.resumed(writer: writer, root: root)
        ..resumeAfter(last);
      expect(restarted.tip, last);
      await note(restarted, 'step 2');

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
    final resumed = TrajectoryChain.resumed(writer: writer, root: root);
    await note(resumed, 'mine');

    // Another writer moves the tip on behind this chain's back: after its
    // first append, a resumed chain refuses rather than following it.
    final other = TrajectoryChain(writer: writer, tip: resumed.tip);
    await note(other, 'not mine');

    await expectLater(
      note(resumed, 'mine again'),
      throwsA(isA<LogbookWriteRefused>()),
    );
  });
}
