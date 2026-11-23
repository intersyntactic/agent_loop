/// The loop's entry point: run as `agent-loop@<loop-user>`, one per
/// trajectory, with no arguments beyond the two logbook sockets — the loop
/// itself gets no sign-in and no network of its own; the airlock makes the
/// model call, under the model and sign-in the trajectory started under
/// (its starting admission's rules, [startingModel]). It finds
/// its own assignment in the logbook rather than being told its trajectory
/// (infra's polkit can start only named template units, so loop_launcher
/// can pass no per-trajectory argument), follows its trajectory's history
/// live (the docking station's admissions and its own turn chain, merged),
/// and, whenever the turn rule says the agent should answer, records a
/// model request and proposes [AskTheModel] through its crux, naming it.
///
/// Each answer is one turn, counted from 0, with one crux for the turn: the
/// model call is its step 0 and the answer its step 1, so a proposal's
/// place is `[turn, step]`. A restarted loop's next turn follows the latest
/// place in its history.
///
/// A trajectory's first proposal is its open notice ([TrajectoryOpened]),
/// in a turn of its own, before its first answer; a trajectory with any
/// proposal already is never sent one ([owesOpenNotice]).
///
/// Once it has the model's reply, answers the message with it by reference
/// only ([ReplyToEvent]: the admission and the reply's outcome entry). Where
/// the answer goes, as whom and in what shape are the airlock's and its
/// module's to work out, so the loop knows no external system. When the
/// model call or the answer is refused, the message is answered instead
/// with a [RefusalNoticeToEvent] naming the refused outcome, so its sender
/// decides what to do; a refused notice or open notice is only logged.
library;

import 'dart:io';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_effects/is_effects.dart' show ModelReply;
import 'package:is_airlock_api/is_airlock_api.dart'
    show
        Action,
        Crux,
        Done,
        Failed,
        ModelCall,
        PlaceInTrajectory,
        Program,
        ReplyToEvent,
        RefusalNoticeToEvent,
        Result,
        TrajectoryOpened;
import 'package:is_logbook_client/is_logbook_client.dart'
    show Kind, LogbookReader, ObjectId;
import 'package:is_shapes/is_shapes.dart' show EntryId;

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
      'usage: agent_loop --logbook-read <socket> --logbook-write <socket>',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  final loopUser = Process.runSync('id', ['-un']).stdout.toString().trim();
  stdout.writeln(
    'agent_loop: ready loopUser=$loopUser '
    'read=${options.logbookRead} write=${options.logbookWrite}',
  );

  final reader = LogbookReader(options.logbookRead);
  final ObjectId root;
  try {
    root = await findTrajectoryRoot(reader, loopUser: loopUser);
  } on NoTrajectoryAssigned catch (e) {
    stderr.writeln('agent_loop: $e');
    exitCode = 1;
    return;
  }
  stdout.writeln('agent_loop: assigned root=${root.hex}');

  final writer = LogbookWriter(options.logbookWrite);
  final turnKind = Kind.parse(_turnKind)!;
  final chain = TrajectoryChain.resumed(
    writer: writer,
    kind: turnKind,
    root: root,
  );
  final link = TrajectoryCrux(chain: chain, returned: followResults(reader));

  final history = <TrajectoryEvent>[];
  var nextTurn = 0;

  // The open notice takes a turn of its own, so a fresh trajectory opens at
  // [0, 0] and its first answer is turn 1. A refusal is logged, not
  // retried: the proposal is in the history either way.
  Future<void> openTrajectory() async {
    final turn = nextTurn++;
    final opened = Program.answerEvent.runOrRefusal<int>(
      const TrajectoryOpened(),
      then: (responses) => Done(responses.length),
    );
    stdout.writeln('agent_loop: proposing the open notice at turn $turn');
    switch (await opened.next(Crux.through(link, turn: turn))) {
      case Done(:final value):
        stdout.writeln('agent_loop: opened, in $value part(s)');
      case Failed(:final why):
        stderr.writeln('agent_loop: open notice refused: $why');
      case Action():
        throw StateError('runOrRefusal returned an unresolved Action');
    }
  }

  // Tells whoever sent [event] that the action at [failed] was refused, and
  // why, at the turn's next step, so they decide what to do. The airlock
  // sends only the reason it recorded. A refused notice is only logged.
  Future<void> noticeRefusal(
    SaidByUser event,
    Crux crux,
    PlaceInTrajectory failed,
  ) async {
    final refusal = link.resultEntryAt(failed);
    if (refusal == null) {
      stderr.writeln(
        'agent_loop: no result entry recorded at $failed, no refusal notice',
      );
      return;
    }
    final noticed = Program.answerEvent.runOrRefusal<int>(
      RefusalNoticeToEvent(
        respondsTo: EntryId.parse(event.hash.hex)!,
        refusal: refusal,
      ),
      then: (responses) => Done(responses.length),
    );
    stdout.writeln(
      'agent_loop: proposing the refusal notice for ${refusal.hex}',
    );
    switch (await noticed.next(crux)) {
      case Done(:final value):
        stdout.writeln('agent_loop: refusal noticed, in $value part(s)');
      case Failed(:final why):
        stderr.writeln('agent_loop: refusal notice refused: $why');
      case Action():
        throw StateError('runOrRefusal returned an unresolved Action');
    }
  }

  Future<void> answer(SaidByUser event) async {
    final starting = startingModel(history);
    final model = starting.model;
    if (model == null) {
      stderr.writeln(
        'agent_loop: ERROR not answering ${event.hash.hex}: no model to '
        'call, since ${starting.why}',
      );
      return;
    }
    final request = encodeModelInput(trajectoryInput(history));
    final requestHash = await recordModelRequestOnTrajectory(
      chain,
      systemPrompt: _placeholderSystemPrompt,
      request: request,
      builtFrom: [for (final e in history) e.hash],
    );
    stdout.writeln('agent_loop: recorded model-request ${requestHash.hex}');

    // One crux for the whole turn: the model call is its step 0, the post
    // its step 1.
    final turn = nextTurn++;
    final crux = Crux.through(link, turn: turn);
    final asked = Program.askTheModel.runOrRefusal<ModelReply>(
      ModelCall(
        signIn: model.signIn,
        model: model.model,
        request: EntryId.parse(requestHash.hex)!,
      ),
      then: (ModelReply reply) => Done(reply),
    );
    final Result<ModelReply> outcome = await asked.next(crux);
    switch (outcome) {
      case Done(:final value):
        stdout.writeln('agent_loop: model replied: ${value.text}');
        try {
          final resultEntry = link.resultEntryAt(PlaceInTrajectory.at(turn, 0));
          if (resultEntry == null) {
            stderr.writeln(
              'agent_loop: no result entry recorded for turn $turn, not '
              'answering',
            );
            break;
          }
          final answered = Program.answerEvent.runOrRefusal<int>(
            ReplyToEvent(
              respondsTo: EntryId.parse(event.hash.hex)!,
              reply: resultEntry,
            ),
            then: (responses) => Done(responses.length),
          );
          stdout.writeln(
            'agent_loop: proposing the answer to ${event.hash.hex} with '
            '${resultEntry.hex}',
          );
          switch (await answered.next(crux)) {
            case Done(:final value):
              stdout.writeln('agent_loop: answered, in $value part(s)');
            case Failed(:final why):
              stderr.writeln('agent_loop: answer refused: $why');
              await noticeRefusal(event, crux, PlaceInTrajectory.at(turn, 1));
            case Action():
              throw StateError('runOrRefusal returned an unresolved Action');
          }
        } on Object catch (e, st) {
          stderr.writeln('agent_loop: answering threw: $e\n$st');
        }
      case Failed(:final why):
        stdout.writeln('agent_loop: model call refused: $why');
        await noticeRefusal(event, crux, PlaceInTrajectory.at(turn, 0));
      case Action():
        // runOrRefusal's own then never returns one: it is called only
        // with the output, never asked to propose a further action.
        throw StateError('runOrRefusal returned an unresolved Action');
    }
  }

  // The backlog is only read, never answered as it arrives: a message in it
  // may already have its answer further on. Once caught up, the loop
  // answers the one message still owed, if any, then every new one live.
  var caughtUp = false;
  await for (final item in followTrajectoryHistory(
    reader,
    turnKind: turnKind,
    chainRoot: root,
  )) {
    switch (item) {
      case CaughtUpWithTrajectory():
        if (caughtUp) continue;
        caughtUp = true;
        if (lastOwnEntry(history) case final lastOwn?) {
          chain.resumeAfter(lastOwn);
        }
        final last = lastPlace(history);
        nextTurn = (last?.turn ?? -1) + 1;
        final owed = unansweredTurn(history);
        stdout.writeln(
          'agent_loop: caught up at place ${last ?? 'none'}, '
          '${owed == null ? 'nothing owed' : 'answering ${owed.hash.hex}'}',
        );
        if (owesOpenNotice(history)) await openTrajectory();
        if (owed != null) await answer(owed);
      case TrajectoryEvent event:
        history.add(event);
        if (!caughtUp) continue;
        if (event is TrajectoryStarted && owesOpenNotice(history)) {
          await openTrajectory();
        }
        if (event is SaidByUser && event.startsTurn) await answer(event);
    }
  }
}

final class _Options {
  const _Options({required this.logbookRead, required this.logbookWrite});

  final String logbookRead;
  final String logbookWrite;

  /// Reads `--logbook-read` and `--logbook-write`.
  static _Options? parse(List<String> args) {
    String? logbookRead;
    String? logbookWrite;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--logbook-read' when i + 1 < args.length:
          logbookRead = args[++i];
        case '--logbook-write' when i + 1 < args.length:
          logbookWrite = args[++i];
        default:
          return null;
      }
    }
    return logbookRead != null && logbookWrite != null
        ? _Options(logbookRead: logbookRead, logbookWrite: logbookWrite)
        : null;
  }
}
