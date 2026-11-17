/// The loop's entry point: run as `agent-loop@<loop-user>`, one per
/// trajectory, with no arguments beyond the two record sockets and which
/// model sign-in and model to ask for (RULINGS: a loop gets no sign-in and
/// no network of its own; the airlock makes the model call). It finds its
/// own assignment in the record rather than being told its trajectory
/// (infra's polkit can start only named template units, so loop_launcher
/// can pass no per-trajectory argument), follows its trajectory's history
/// live (the docking station's admissions and its own turn chain, merged),
/// and, whenever the turn rule says the agent should answer, records a
/// model request and proposes [AskTheModel] through its crux, naming it.
///
/// The `place` a proposal names is its turn number, counted from 1
/// (confirmed with airlock-api-04: the airlock service's P for this
/// trajectory kind is an int, read at airlock lib/src/airlock_subscriber.dart;
/// one proposal per turn here, so each turn is its own place).
///
/// Once it has the model's reply, posts it to Teams: the triggering
/// SaidByUser's rawEventEntry names the relay's own raw activity, read back
/// to get the serviceUrl a reply needs (teams-module-e2, 2026-11-18 03:18 —
/// confirmed against a live 201, not guessed, including that the body must
/// be built key-'type'-before-'text' or the airlock's byte check refuses
/// it). A call the airlock refuses, or one with no triggering SaidByUser in
/// reach (shouldn't happen: a turn only starts from one), is logged, not
/// thrown — the model's answer is already recorded either way.
library;

import 'dart:io';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_docking_station/is_docking_station.dart' show RelayedEvent;
import 'package:is_effects/is_effects.dart'
    show ModelName, ModelReply, ModelSignInName, SignIn;
import 'package:is_airlock_api/is_airlock_api.dart'
    show
        Action,
        Crux,
        Done,
        Failed,
        ModelCall,
        Program,
        Projection,
        Result,
        WebRequest;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart'
    show LogbookReader, ObjectId;
import 'package:is_shapes/is_shapes.dart' show EntryId;
import 'package:is_teams_module/is_teams_module.dart'
    show TeamsPost, teamsPostRequest, teamsRecordedEvent;

/// Who every Teams reply goes out as (the origin itself comes from each
/// activity's own serviceUrl, which teamsPostRequest reads — not fixed
/// here, since it differs per tenant): from infra's own flight rules
/// (enspyrco/infra intersyntactic-docking-station's
/// what-may-leave-this-machine.json), fixed for this one demo integration,
/// not yet a flag.
final _teamsSignIn = SignIn.parse('cam-teams')!;

/// Until the tool-intent-as-text design lands (task 10), a fixed, labelled
/// placeholder: enough to exercise recording for real, not what the demo's
/// system prompt will actually say.
const _placeholderSystemPrompt =
    'You are the agent in this conversation. Reply in plain text; no tools '
    'are available.';

const _turnKind = 'turn';

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options == null) {
    stderr.writeln(
      'usage: agent_loop --record-read <socket> --record-write <socket> '
      '--model-sign-in <name> --model <name>',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  final loopUser = Process.runSync('id', ['-un']).stdout.toString().trim();
  stdout.writeln(
    'agent_loop: ready loopUser=$loopUser '
    'read=${options.recordRead} write=${options.recordWrite}',
  );

  final reader = LogbookReader(options.recordRead);
  final ObjectId root;
  try {
    root = await findTrajectoryRoot(reader, loopUser: loopUser);
  } on NoTrajectoryAssigned catch (e) {
    stderr.writeln('agent_loop: $e');
    exitCode = 1;
    return;
  }
  stdout.writeln('agent_loop: assigned root=${root.hex}');

  final writer = LogbookWriter(options.recordWrite);
  final turnKind = Kind.parse(_turnKind)!;
  final chain = TrajectoryChain(writer: writer, kind: turnKind, tip: root);
  final link = TrajectoryCrux(chain: chain, returned: followResults(reader));

  final history = <TrajectoryEvent>[];
  var turn = 0;
  await for (final event in followTrajectoryHistory(
    reader,
    turnKind: turnKind,
    chainRoot: root,
  )) {
    history.add(event);
    if (event is! SaidByUser || !event.startsTurn) continue;

    final request = renderTrajectoryHistory(history);
    final requestHash = await recordModelRequestOnTrajectory(
      chain,
      systemPrompt: _placeholderSystemPrompt,
      request: request,
      builtFrom: [
        for (final e in history)
          switch (e) {
            SaidByUser(:final hash) => hash,
            TurnOnChain(:final hash) => hash,
          },
      ],
    );
    stdout.writeln('agent_loop: recorded model-request ${requestHash.hex}');

    final crux = Crux.through(link, place: ++turn);
    final asked = Program.askTheModel.runOrRefusal<ModelReply>(
      ModelCall(
        signIn: options.modelSignIn,
        model: options.model,
        request: EntryId.parse(requestHash.hex)!,
      ),
      then: (ModelReply reply) => Done(reply),
    );
    final Result<ModelReply> outcome = await asked.next(crux);
    switch (outcome) {
      case Done(:final value):
        stdout.writeln('agent_loop: model replied: ${value.text}');
        try {
          final resultEntry = link.resultEntryAt(turn);
          if (resultEntry == null) {
            stderr.writeln(
              'agent_loop: no result entry recorded for turn $turn, not '
              'posting to Teams',
            );
            break;
          }
          stdout.writeln('agent_loop: result entry ${resultEntry.hex}');
          final rawEvent = event.rawEvent;
          if (rawEvent == null) {
            stderr.writeln(
              'agent_loop: no raw event arrived before this admission, not '
              'posting to Teams',
            );
            break;
          }
          stdout.writeln('agent_loop: triggering raw event ${rawEvent.id}');
          final relayed = RelayedEvent.read(rawEvent.id, rawEvent.body);
          final teamsEvent = relayed == null
              ? null
              : teamsRecordedEvent(relayed.bytes);
          if (teamsEvent == null) {
            stderr.writeln(
              'agent_loop: the triggering event is not a Teams activity',
            );
            break;
          }
          stdout.writeln(
            'agent_loop: decoded Teams event, serviceUrl '
            '${teamsEvent.serviceUrl}',
          );
          final built = teamsPostRequest(
            TeamsPost(
              serviceUrl: teamsEvent.serviceUrl,
              conversation: teamsEvent.conversation,
              activity: {'type': 'message', 'text': value.text},
            ),
            _teamsSignIn,
          );
          stdout.writeln('agent_loop: built Teams post request');
          final webRequest = WebRequest(
            built.origin,
            body: built.body!,
            projection: Projection.teamsMessageFromModelReply,
            drawnFrom: resultEntry,
            method: built.method,
            path: built.path,
            signIn: built.signIn,
            headers: built.headers,
          );
          final posted = Program.web.runOrRefusal<void>(
            webRequest,
            then: (_) => const Done(null),
          );
          stdout.writeln('agent_loop: proposing the Teams post');
          switch (await posted.next(Crux.through(link, place: ++turn))) {
            case Done():
              stdout.writeln('agent_loop: posted the reply to Teams');
            case Failed(:final why):
              stderr.writeln('agent_loop: Teams post refused: $why');
            case Action():
              throw StateError('runOrRefusal returned an unresolved Action');
          }
        } on Object catch (e, st) {
          stderr.writeln('agent_loop: posting to Teams threw: $e\n$st');
        }
      case Failed(:final why):
        stdout.writeln('agent_loop: model call refused: $why');
      case Action():
        // runOrRefusal's own then never returns one: it is called only
        // with the output, never asked to propose a further action.
        throw StateError('runOrRefusal returned an unresolved Action');
    }
  }
}

final class _Options {
  const _Options({
    required this.recordRead,
    required this.recordWrite,
    required this.modelSignIn,
    required this.model,
  });

  final String recordRead;
  final String recordWrite;
  final ModelSignInName modelSignIn;
  final ModelName model;

  static _Options? parse(List<String> args) {
    String? recordRead;
    String? recordWrite;
    ModelSignInName? modelSignIn;
    ModelName? model;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--record-read' when i + 1 < args.length:
          recordRead = args[++i];
        case '--record-write' when i + 1 < args.length:
          recordWrite = args[++i];
        case '--model-sign-in' when i + 1 < args.length:
          modelSignIn = ModelSignInName.parse(args[++i]);
        case '--model' when i + 1 < args.length:
          model = ModelName.parse(args[++i]);
        default:
          return null;
      }
    }
    return recordRead != null &&
            recordWrite != null &&
            modelSignIn != null &&
            model != null
        ? _Options(
            recordRead: recordRead,
            recordWrite: recordWrite,
            modelSignIn: modelSignIn,
            model: model,
          )
        : null;
  }
}
