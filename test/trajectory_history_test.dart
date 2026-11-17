// Proves followTrajectoryHistory and renderTrajectoryHistory against a
// real LogbookService: a docking-station-shaped event-admitted-to-mission
// entry (built with is_docking_station's own encodeDecision, not
// hand-written JSON) interleaves correctly with the loop's own turns, in
// logbook order, and renders the same as the old UserSaid-turn path did.
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show SourceMessageId, UserSaid;
import 'package:is_docking_station/is_docking_station.dart';
import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';
import 'package:is_logbook_client/is_logbook_client.dart' show LogbookReader;
import 'package:is_logbook_client/is_logbook_client.dart' as client;
import 'package:is_shapes/is_shapes.dart' show ActorId, DecidedBy, TrajectoryId;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late LogbookService service;
  late client.LogbookWriter rawWriter;
  late LogbookReader reader;
  late String uid;
  final turnKind = Kind.parse('turn')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_history_test_');
    uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList(
        '$uid turn users-assigned-to-trajectory '
                'event-admitted-to-mission\n'
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
    reader = LogbookReader('${tmp.path}/logbook.read.sock');
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  test('merges an admitted message with the loop\'s own turn, oldest '
      'first, and renders both', () async {
    final rootResult = await rawWriter.write(
      Kind.usersAssignedToTrajectory,
      Uint8List.fromList(
        '{"trajectory":"${EntryHash.origin.hex}",'
                '"mission":"${client.ObjectId.of(Uint8List.fromList('m'.codeUnits)).hex}",'
                '"loopUser":"$uid","suit":"1002"}'
            .codeUnits,
      ),
    );
    final root = (rootResult as client.Written).entry;

    // The admission that admits the user's message, exactly as the
    // docking station would encode it.
    final admission = EventAdmittedToMission(
      client.ObjectId.of(Uint8List.fromList('event'.codeUnits)),
      by: DecidedBy.rules,
      reading: MessageSaid(
        addressInExternalSystem: AddressInExternalSystem.parse('teams:c1')!,
        containingAddress: null,
        key: EventKey.parse('k1')!,
        node: UserSaid(
          author: ActorId.parse('teams:u1')!,
          source: SourceMessageId.parse('m1')!,
          text: 'hey are you there',
        ),
      ),
      placement: OnTrajectory(TrajectoryId.parse('a1' * 32)!),
      startsTurn: true,
    );
    final (admittedKind, admittedBody) = encodeDecision(admission);
    final admittedResult = await rawWriter.write(admittedKind, admittedBody);
    final admittedHash = (admittedResult as client.Written).entry;

    final chain = TrajectoryChain(
      writer: LogbookWriter('${tmp.path}/logbook.sock'),
      kind: turnKind,
      tip: root,
    );
    final turnHash = await chain.append({
      'shape': 'UserSaid',
      'author': 'teams:u1',
      'source': 'm2',
      'text': 'a loop-written turn',
    }, const Own());

    final found = <TrajectoryEvent>[];
    // Not cancelled: see trajectory_chain_test.dart's own note — the hang
    // is in followTrajectoryHistory's own async* wrapping, not in
    // is_logbook_client 0.2.0's subscribe(), which fixed its own.
    followTrajectoryHistory(
      reader,
      turnKind: turnKind,
      chainRoot: root,
    ).listen(found.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(found, hasLength(2));
    expect(found[0], isA<SaidByUser>());
    expect((found[0] as SaidByUser).hash, admittedHash);
    expect((found[0] as SaidByUser).text, 'hey are you there');
    expect((found[0] as SaidByUser).startsTurn, isTrue);
    expect(found[1], isA<TurnOnChain>());
    expect((found[1] as TurnOnChain).hash, turnHash);

    expect(
      renderTrajectoryHistory(found),
      'User: hey are you there\nUser: a loop-written turn',
    );
  });
}
