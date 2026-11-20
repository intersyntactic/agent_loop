// Proves followTrajectoryHistory and trajectoryInput against a
// real LogbookService: a docking-station-shaped event-admitted-to-mission
// entry (built with is_docking_station's own encodeDecision, not
// hand-written JSON) interleaves correctly with the loop's own turns, in
// logbook order, and becomes one input item per event.
import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart'
    show
        Crux,
        Done,
        ModelCall,
        PlaceInTrajectory,
        Program,
        outcomeOfProposedActionKind,
        outcomeOfProposedActionToJson;
import 'package:is_effects/is_effects.dart'
    show
        CutOffReply,
        FinishedReply,
        ModelAndSignIn,
        ModelName,
        ModelReply,
        ModelSignInName,
        Outcome,
        Ran,
        Refused,
        encodeModelReply,
        encodeOutcome;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show SourceMessageId, UserSaid;
import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_docking_station/is_docking_station.dart';
import 'package:is_flight_rules/is_flight_rules.dart'
    show FlightRules, ProgramsNetwork, WhatMayLeaveThisMachine;
import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';
import 'package:is_logbook_client/is_logbook_client.dart' show LogbookReader;
import 'package:is_logbook_client/is_logbook_client.dart' as client;
import 'package:is_shapes/is_shapes.dart'
    show ActorId, DecidedBy, EntryId, TrajectoryId;
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
    tmp = Directory.systemTemp.createTempSync('agent_loop_history_test_');
    uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList(
        '$uid turn users-assigned-to-trajectory '
                'event-admitted-to-mission event '
                'action-proposed-by-agent-loop outcome-of-proposed-action\n'
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
        '{"trajectory":"$trajectoryUnderTest",'
                '"mission":"${client.ObjectId.of(Uint8List.fromList('m'.codeUnits)).hex}",'
                '"loopUser":"$uid","suit":"1002"}'
            .codeUnits,
      ),
    );
    final root = (rootResult as client.Written).entry;

    // The relay's own raw event, written before the admission that names
    // it, as loop_launcher's feed now delivers it.
    final eventKind = Kind.parse('event')!;
    final rawEventBody = utf8.encode('{"type":"message"}');
    final rawEventResult = await rawWriter.write(
      eventKind,
      Uint8List.fromList(rawEventBody),
    );
    final rawEventEntry = (rawEventResult as client.Written).entry;

    // The admission that admits the user's message, exactly as the
    // docking station would encode it.
    final admission = EventAdmittedToMission(
      rawEventEntry,
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

    final items = <TrajectoryFeedItem>[];
    final sub = followTrajectoryHistory(
      reader,
      turnKind: turnKind,
      chainRoot: root,
    ).listen(items.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();
    final found = items.whereType<TrajectoryEvent>().toList();

    expect(items.last, isA<CaughtUpWithTrajectory>());
    expect(found, hasLength(2));
    expect(found[0], isA<SaidByUser>());
    expect((found[0] as SaidByUser).hash, admittedHash);
    expect((found[0] as SaidByUser).text, 'hey are you there');
    expect((found[0] as SaidByUser).startsTurn, isTrue);
    expect(
      (found[0] as SaidByUser).address,
      AddressInExternalSystem.parse('teams:c1'),
    );
    expect((found[0] as SaidByUser).rawEvent?.id, rawEventEntry);
    expect((found[0] as SaidByUser).rawEvent?.body, rawEventBody);
    expect(found[1], isA<TurnOnChain>());
    expect((found[1] as TurnOnChain).hash, turnHash);

    expect(jsonDecode(encodeModelInput(trajectoryInput(found))), [
      {'role': 'user', 'content': 'hey are you there'},
      {'role': 'user', 'content': 'a loop-written turn'},
    ]);
  });

  group('the model a trajectory started under', () {
    final claude = ModelAndSignIn(
      signIn: ModelSignInName.parse('nick-claude-team')!,
      model: ModelName.parse('claude-opus-5-5')!,
    );
    WhatMayLeaveThisMachine allowing(String signIn) => WhatMayLeaveThisMachine(
      modelSignInsCallsMayGoOutAs: [ModelSignInName.parse(signIn)!],
      sitesTheWebDriverMayReach: const [],
      programsNetwork: ProgramsNetwork.values.first,
    );

    // Writes an admission of [text], starting a new trajectory and mission
    // under [rules] when they are given, and returns everything the feed
    // then hands on.
    Future<List<TrajectoryEvent>> admit(
      List<(String text, JsonObject? rules)> messages,
    ) async {
      final rootResult = await rawWriter.write(
        Kind.usersAssignedToTrajectory,
        Uint8List.fromList(
          '{"trajectory":"$trajectoryUnderTest",'
                  '"mission":"${client.ObjectId.of(Uint8List.fromList('m'.codeUnits)).hex}",'
                  '"loopUser":"$uid","suit":"1002"}'
              .codeUnits,
        ),
      );
      final root = (rootResult as client.Written).entry;
      for (final (i, (text, rules)) in messages.indexed) {
        final raw = await rawWriter.write(
          Kind.parse('event')!,
          Uint8List.fromList(utf8.encode('{"n":$i}')),
        );
        final (kind, body) = encodeDecision(
          EventAdmittedToMission(
            (raw as client.Written).entry,
            by: DecidedBy.rules,
            reading: MessageSaid(
              addressInExternalSystem: AddressInExternalSystem.parse(
                'teams:c1',
              )!,
              containingAddress: null,
              key: EventKey.parse('k$i')!,
              node: UserSaid(
                author: ActorId.parse('teams:u1')!,
                source: SourceMessageId.parse('m$i')!,
                text: text,
              ),
            ),
            placement: rules == null
                ? OnTrajectory(TrajectoryId.parse('a1' * 32)!)
                : const StartsTrajectory(StartsMission()),
            rules: rules,
            startsTurn: true,
          ),
        );
        await rawWriter.write(kind, body);
      }
      final items = <TrajectoryFeedItem>[];
      final sub = followTrajectoryHistory(
        reader,
        turnKind: turnKind,
        chainRoot: root,
      ).listen(items.add);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      return items.whereType<TrajectoryEvent>().toList();
    }

    test('comes from the rules on the admission that started it; a '
        'follow-up carries none', () async {
      final rules = FlightRules.of(
        whatMayLeaveThisMachine: allowing('nick-claude-team'),
        startingModel: claude,
      )!.toJson();
      final found = await admit([('first', rules), ('follow-up', null)]);

      expect(
        [for (final e in found) e.runtimeType],
        [TrajectoryStarted, SaidByUser, SaidByUser],
      );
      expect(startingModel(found).model, claude);
      // The rules are not part of the conversation.
      expect(jsonDecode(encodeModelInput(trajectoryInput(found))), [
        {'role': 'user', 'content': 'first'},
        {'role': 'user', 'content': 'follow-up'},
      ]);
    });

    test('rules whose starting sign-in they do not allow give no model, '
        'and say why', () async {
      final notAllowed = JsonObject.of({
        'whatMayLeaveThisMachine': allowing('cam-chatgpt').toJson(),
        'startingModel': {
          'signIn': 'nick-claude-team',
          'model': 'claude-opus-5-5',
        },
      });
      final found = await admit([('first', notAllowed)]);

      expect(found.first, isA<TrajectoryRulesUnreadable>());
      final starting = startingModel(found);
      expect(starting.model, isNull);
      expect(starting.why, contains('startingModel.signIn'));
    });

    test(
      'a trajectory whose start the loop never saw gives no model',
      () async {
        final found = await admit([('follow-up', null)]);

        expect(startingModel(found).model, isNull);
        expect(startingModel(found).why, contains('no admission'));
      },
    );
  });

  test('a model call the airlock ran comes back as the agent\'s reply; a '
      'refused one is skipped', () async {
    final rootResult = await rawWriter.write(
      Kind.usersAssignedToTrajectory,
      Uint8List.fromList(
        '{"trajectory":"$trajectoryUnderTest",'
                '"mission":"${client.ObjectId.of(Uint8List.fromList('m'.codeUnits)).hex}",'
                '"loopUser":"$uid","suit":"1002"}'
            .codeUnits,
      ),
    );
    final root = (rootResult as client.Written).entry;
    final chain = TrajectoryChain(
      writer: LogbookWriter('${tmp.path}/logbook.sock'),
      kind: turnKind,
      tip: root,
    );

    // Each call is proposed through the loop's real crux; the airlock's
    // answer is written as it would write it, then handed back to the crux.
    final returned = StreamController<ReturnedResult>();
    final link = TrajectoryCrux(chain: chain, returned: returned.stream);
    final outcomeKind = Kind.parse(outcomeOfProposedActionKind)!;
    Future<client.ObjectId> answer(
      int place,
      Outcome<ModelReply> outcome,
    ) async {
      final asked = Program.askTheModel.runOrRefusal<ModelReply>(
        ModelCall(
          signIn: ModelSignInName.parse('anthropic-api')!,
          model: ModelName.parse('claude-opus-5-5')!,
          request: EntryId.parse('ab' * 32)!,
        ),
        then: (ModelReply reply) => Done(reply),
      );
      final before = chain.tip;
      final done = asked.next(Crux.through(link, turn: place));
      while (chain.tip == before) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final proposed = EntryId.parse(chain.tip!.hex)!;
      final body = jsonEncode(
        outcomeOfProposedActionToJson(
          proposed,
          encodeOutcome(outcome, encodeModelReply),
        ),
      );
      final written = await rawWriter.write(
        outcomeKind,
        Uint8List.fromList(utf8.encode(body)),
      );
      final entry = (written as client.Written).entry;
      returned.add((
        proposed: proposed,
        resultEntry: EntryId.parse(entry.hex)!,
        body: body,
      ));
      await done;
      return entry;
    }

    final ranHash = await answer(
      1,
      const Ran(FinishedReply(text: 'yes, here')),
    );
    await answer(2, const Refused('no sign-in'));
    final cutHash = await answer(3, const Ran(CutOffReply(text: 'half an')));

    final items = <TrajectoryFeedItem>[];
    final sub = followTrajectoryHistory(
      reader,
      turnKind: turnKind,
      chainRoot: root,
    ).listen(items.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();
    await returned.close();
    final found = items.whereType<TrajectoryEvent>().toList();

    // Both proposals come back, each with its place; only the call that ran
    // comes back as a reply.
    expect(
      [
        for (final e in found)
          switch (e) {
            ActionProposed(:final place, :final asksTheModel) =>
              'proposed $place model=$asksTheModel',
            SaidByAgent(:final hash) =>
              'reply ${hash == ranHash
                  ? 'ran'
                  : hash == cutHash
                  ? 'cut'
                  : '?'}',
            SaidByUser() ||
            TurnOnChain() ||
            TrajectoryStarted() ||
            TrajectoryRulesUnreadable() => '${e.runtimeType}',
          },
      ],
      [
        'proposed 1.0 model=true',
        'reply ran',
        'proposed 2.0 model=true',
        'proposed 3.0 model=true',
        'reply cut',
      ],
    );
    expect(lastPlace(found), PlaceInTrajectory.at(3, 0));
    // A cut-off reply reaches the model marked as cut off, never as finished.
    expect(jsonDecode(encodeModelInput(trajectoryInput(found))), [
      {'role': 'assistant', 'content': 'yes, here'},
      {
        'role': 'assistant',
        'content': 'half an\n\n(This reply was cut off before it finished.)',
      },
    ]);
  });
}
