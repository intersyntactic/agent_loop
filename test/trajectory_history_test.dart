// Proves followTrajectoryHistory and trajectoryInput against a
// real LogbookService: a docking-station-shaped event-admitted-to-mission
// entry (built with is_docking_station_api's own encodeDecision, not
// hand-written JSON) interleaves correctly with the loop's own turns, in
// logbook order, and becomes one input item per event.
import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart'
    show
        ActionProposedByAgentLoop,
        Crux,
        Done,
        ModelCall,
        ProposedForTheModelCall,
        Program,
        outcomeOfProposedActionKind,
        outcomeOfProposedActionToJson;
import 'package:is_effects/is_effects.dart'
    show
        AddressPrefix,
        CutOffReply,
        FinishedReply,
        ModelAndSignIn,
        ModelName,
        ModelReply,
        ModelSignInName,
        Origin,
        Outcome,
        PathPrefix,
        NothingRan,
        Ran,
        SignIn,
        StoppedPartway,
        TextBody,
        WebPath,
        WebResponse,
        encodeModelReply,
        encodeOutcome,
        encodeWebResponse;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show SourceMessageId, UserSaid;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show ToolFailed, ToolName, ToolRan, ToolRefused;
import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_conversation_reply_vocabulary/is_conversation_reply_vocabulary.dart'
    show RepliesUnderWebAddress;
import 'package:is_docking_station_api/is_docking_station_api.dart';
import 'package:is_flight_rules/is_flight_rules.dart'
    show FlightRules, ProgramsNetwork, WhatMayLeaveThisMachine;
import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';
import 'package:is_logbook_client/is_logbook_client.dart' show LogbookReader;
import 'package:is_logbook_client/is_logbook_client.dart' as client;
import 'package:is_shapes/is_shapes.dart'
    show ActorId, DecidedBy, EntryId, TrajectoryId;
import 'package:is_tools_api/is_tools_api.dart'
    show Fetch, Input, OneActionTool;
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
    // it: the loop never subscribes to it, so it never shows in the feed.
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
      translatedEvent: MessageSaid(
        addressInExternalSystem: AddressInExternalSystem.parse('teams:c1')!,
        containingAddress: null,
        replyEndpoint: null,
        key: EventKey.parse('k1')!,
        addressedTo: ActorId.parse('teams:cam')!,
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
    expect(found[1], isA<TurnOnChain>());
    expect((found[1] as TurnOnChain).hash, turnHash);

    expect(_turnsOf(found), [
      {'kind': 'user', 'text': 'hey are you there'},
      {'kind': 'user', 'text': 'a loop-written turn'},
    ]);
  });

  group('the model a trajectory started under', () {
    final claude = ModelAndSignIn(
      signIn: ModelSignInName.parse('nick-claude-team')!,
      model: ModelName.parse('claude-opus-5-5')!,
    );
    WhatMayLeaveThisMachine allowing(String signIn) => WhatMayLeaveThisMachine(
      modelSignInsCallsMayGoOutAs: [ModelSignInName.parse(signIn)!],
      fetchesMayReach: const [],
      webRequestsMayReach: const [],
      programsNetwork: ProgramsNetwork.values.first,
    );

    // Where every admitted message says replies go.
    final endpoint = RepliesUnderWebAddress(
      AddressPrefix.of(
        Origin.parse('https://smba.trafficmanager.net')!,
        PathPrefix.parse('/amer/v3/conversations/c1/')!,
      ),
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
            translatedEvent: MessageSaid(
              addressInExternalSystem: AddressInExternalSystem.parse(
                'teams:c1',
              )!,
              containingAddress: null,
              replyEndpoint: endpoint,
              key: EventKey.parse('k$i')!,
              addressedTo: null,
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
        programsItMayRun: const [],
        programsItNeeds: const [],
        givenTools: const [],
      )!.toJson();
      final found = await admit([('first', rules), ('follow-up', null)]);

      expect(
        [for (final e in found) e.runtimeType],
        [TrajectoryStarted, SaidByUser, SaidByUser],
      );
      expect(startingModel(found).model, claude);
      // The start carries where replies go, and the trajectory's own id.
      final started = found.first as TrajectoryStarted;
      expect(started.replyEndpoint, endpoint);
      expect(started.trajectory.hex, started.hash.hex);
      // The rules are not part of the conversation.
      expect(_turnsOf(found), [
        {'kind': 'user', 'text': 'first'},
        {'kind': 'user', 'text': 'follow-up'},
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
        'programsItMayRun': <Object?>[],
        'programsItNeeds': <Object?>[],
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
      'refused one ends its call with nothing said; each names its call', () async {
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
      int turn,
      Outcome<ModelReply> outcome,
    ) async {
      final asked = Program.askTheModel.runOrFail<ModelReply>(
        ModelCall(
          signIn: ModelSignInName.parse('anthropic-api')!,
          model: ModelName.parse('claude-opus-5-5')!,
          request: EntryId.parse('ab' * 32)!,
        ),
        then: (ModelReply reply) => Done(reply),
      );
      final before = chain.tip;
      final done = asked.next(Crux.forTheModelCall(link, turn: turn));
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
    await answer(2, const NothingRan('no sign-in'));
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

    // Every proposal comes back with its place, then its call's end: a reply
    // for a call that ran, a refusal for one that didn't.
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
            ModelCallRefused() => 'refused',
            FetchEnded() ||
            SaidByUser() ||
            TurnOnChain() ||
            TrajectoryStarted() ||
            TrajectoryRulesUnreadable() => '${e.runtimeType}',
          },
      ],
      [
        'proposed 1.model-call model=true',
        'reply ran',
        'proposed 2.model-call model=true',
        'refused',
        'proposed 3.model-call model=true',
        'reply cut',
      ],
    );
    // Each end names the proposal just before it, so every call has ended.
    for (final (i, e) in found.indexed) {
      if (e
          case SaidByAgent(:final proposed) ||
              ModelCallRefused(:final proposed)) {
        expect(proposed, found[i - 1].hash);
      }
    }
    expect(
      actionsSettled(found, latestOwn: ProposedForTheModelCall.at(3)),
      isTrue,
    );
    expect(lastPlace(found), ProposedForTheModelCall.at(3));
    // A cut-off reply reaches the model marked as cut off, never as finished.
    expect(_turnsOf(found), [
      {'kind': 'agent', 'text': 'yes, here'},
      {
        'kind': 'agent',
        'text': 'half an\n\n(This reply was cut off before it finished.)',
      },
    ]);
  });

  test('a tool\'s fetch is proposed as the tool says, at the turn\'s one '
      'intent, and its outcome comes back as what the model is shown', () async {
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
    final returned = StreamController<ReturnedResult>();
    final link = TrajectoryCrux(chain: chain, returned: returned.stream);
    final outcomeKind = Kind.parse(outcomeOfProposedActionKind)!;
    final tool = OneActionTool.of(
      name: ToolName.of('list_documents'),
      description: 'Lists the channel folder.',
      input: Input.none,
      action: Fetch(
        Origin.parse('https://graph.microsoft.com')!,
        WebPath.parse('/v1.0/drives/b!xyz/items/01F/children')!,
        SignIn.parse('enspyr-test')!,
      ),
    );

    // Runs the tool at [turn]'s intent, answering as the airlock would.
    Future<String> run(int turn, Outcome<WebResponse> outcome) async {
      final before = chain.tip;
      final done = toolAction(tool)
          .next(Crux.forIntent(link, turn: turn, intent: 0));
      while (chain.tip == before) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final proposedEntry = chain.tip!;
      final proposed = EntryId.parse(proposedEntry.hex)!;
      final body = jsonEncode(
        outcomeOfProposedActionToJson(
          proposed,
          encodeOutcome(outcome, encodeWebResponse),
        ),
      );
      final written = await rawWriter.write(
        outcomeKind,
        Uint8List.fromList(utf8.encode(body)),
      );
      returned.add((
        proposed: proposed,
        resultEntry: EntryId.parse((written as client.Written).entry.hex)!,
        body: body,
      ));
      await done;
      return proposedEntry.hex;
    }

    final firstProposal = await run(
      0,
      const Ran(WebResponse(status: 200, body: TextBody('3 files'))),
    );
    await run(
      1,
      const Ran(WebResponse(status: 403, refusedBecause: 'accessDenied')),
    );
    await run(2, const NothingRan('no grant lets it out'));
    await run(
      3,
      const StoppedPartway<WebResponse>(why: 'the socket closed', done: null),
    );

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

    expect(
      [
        for (final e in found)
          switch (e) {
            ActionProposed(:final place, :final program) =>
              'proposed $place ${program.name}',
            FetchEnded(result: ToolRan(:final text)) => 'ran: $text',
            FetchEnded(result: ToolFailed(:final text)) => 'failed: $text',
            FetchEnded(result: ToolRefused(:final why)) => 'refused: $why',
            SaidByAgent() ||
            ModelCallRefused() ||
            SaidByUser() ||
            TurnOnChain() ||
            TrajectoryStarted() ||
            TrajectoryRulesUnreadable() => '${e.runtimeType}',
          },
      ],
      [
        'proposed 0.0.0 fetchFromWeb',
        'ran: 3 files',
        'proposed 1.0.0 fetchFromWeb',
        'failed: the site answered 403: accessDenied',
        'proposed 2.0.0 fetchFromWeb',
        'refused: no grant lets it out',
        'proposed 3.0.0 fetchFromWeb',
        "failed: it stopped partway, so it may have partly happened; don't "
            'retry it: the socket closed',
      ],
    );
    // The proposal carries the tool's own address and sign-in, and keeps
    // the body as text.
    final proposal = found.firstWhere((e) => e.hash.hex == firstProposal);
    final entry = await _entryBody(reader, proposal.hash);
    expect(jsonDecode(entry), {
      'place': [0, 0, 0],
      'program': 'fetch',
      'input': {
        'origin': 'https://graph.microsoft.com',
        'path': '/v1.0/drives/b!xyz/items/01F/children',
        'signIn': 'enspyr-test',
        'keep': 'text',
      },
    });
  });
}

/// The turns a model request built from [found] carries, as their JSON.
List<Map<String, Object?>> _turnsOf(List<TrajectoryEvent> found) => [
  for (final turn in trajectoryInput(found, tools: const {}))
    turn.toJson().asUncheckedMap(),
];

/// The body of [id]'s entry, read from [reader]'s backlog.
Future<String> _entryBody(LogbookReader reader, client.ObjectId id) async {
  await for (final item in reader.subscribe(
    kinds: {Kind.parse(ActionProposedByAgentLoop.kind)!},
  )) {
    if (item case client.Entry(id: final entryId, :final body)
        when entryId == id) {
      return utf8.decode(body);
    }
  }
  throw StateError('no entry ${id.hex}');
}
