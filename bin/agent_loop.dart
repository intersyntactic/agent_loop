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
/// Each answer is one turn, counted from 0: its model call through
/// [Crux.forTheModelCall], then its reply through [Crux.forTheReply]. A
/// restarted loop's next turn follows the latest place in its history.
///
/// A reply is two actions ([replyActions]): run the program named by
/// `--reply-drawing`, such as teams_module's `teams-reply-drawing`, which
/// draws the reply as its surface's requests, then send exactly those. They
/// go to the reply endpoint the trajectory's starting admission recorded,
/// as the sign-in
/// its rules' reply grant goes as ([WhatMayLeaveThisMachine.signInForReply]),
/// so the loop knows no external system, and the airlock decides where each
/// request goes. Without a drawing, an endpoint or a sign-in, nothing is
/// sent and the loop says why.
///
/// When the model call is refused, the turn's reply says why, so its sender
/// decides what to do. A refused reply is only logged: the way back to the
/// person is what failed.
///
/// The model is shown the tools the trajectory's rules give it
/// ([toolsPrompt]). A reply that calls one ends its turn with the tool's
/// action, proposed at the turn's one intent ([toolAction]); the next turn
/// asks the model again with the result. What to do next is always read
/// from the history ([stepOwed]), so a restarted loop picks up a tool call
/// where it left off.
library;

import 'dart:io';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_effects/is_effects.dart'
    show ModelReply, ModelUsage, ProgramName;
import 'package:is_airlock_api/is_airlock_api.dart'
    show
        Action,
        Crux,
        Done,
        Executable,
        Failed,
        ModelCall,
        PlaceInTrajectory,
        Program,
        ProposedForAnIntent,
        ProposedForTheModelCall,
        ProposedForTheReply,
        Result;
import 'package:is_flight_rules/is_flight_rules.dart'
    show WhatMayLeaveThisMachine;
import 'package:is_logbook_client/is_logbook_client.dart'
    show Kind, LogbookReader, ObjectId;
import 'package:is_shapes/is_shapes.dart' show EntryId;
import 'package:is_tools_api/is_tools_api.dart' show OneActionTool;

/// A fixed, labelled placeholder for what the system prompt says before
/// its tools: enough to exercise recording for real, not what a demo's
/// system prompt will actually say.
const _placeholderSystemPrompt =
    'You are the agent in this conversation. Reply in plain text.';

/// The system prompt for a trajectory given [tools]: constant for the
/// trajectory, since its rules are.
String _systemPrompt(Map<String, OneActionTool> tools) => [
  _placeholderSystemPrompt,
  if (tools.isNotEmpty) toolsPrompt(tools.values),
].join('\n\n');

const _turnKind = 'turn';

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options == null) {
    stderr.writeln(
      'usage: agent_loop --logbook-read <socket> --logbook-write <socket> '
      '[--reply-drawing <program>]',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  final loopUser = Process.runSync('id', ['-un']).stdout.toString().trim();
  stdout.writeln(
    'agent_loop: ready loopUser=$loopUser '
    'read=${options.logbookRead} write=${options.logbookWrite} '
    'replyDrawing=${options.replyDrawing?.name ?? 'none'}',
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
  // The latest place this loop proposed at: until its proposal is in
  // history, nothing next is owed.
  PlaceInTrajectory? latestOwn;

  Map<String, OneActionTool> tools() =>
      history.whereType<TrajectoryStarted>().firstOrNull?.rules.givenTools ??
      const {};

  // Says [text] back to whoever started the trajectory, as [turn]'s reply,
  // footered with [usage] when the model call reported it. A refused reply
  // is only logged: there is no other way back.
  Future<void> sayBack(
    int turn,
    String text,
    String what, {
    ModelUsage? usage,
  }) async {
    final drawing = options.replyDrawing;
    final started = history.whereType<TrajectoryStarted>().firstOrNull;
    final endpoint = started?.replyEndpoint;
    if (drawing == null || started == null || endpoint == null) {
      stderr.writeln(
        'agent_loop: $what not sent: '
        '${drawing == null ? 'no --reply-drawing' : 'no reply endpoint'}',
      );
      return;
    }
    final signIn = started.rules.whatMayLeaveThisMachine.signInForReply(
      replyEndpoint: endpoint,
      leasedNow: const {},
      pooled: const {},
    );
    if (signIn == null) {
      stderr.writeln(
        "agent_loop: $what not sent: the rules' reply grants go as no one",
      );
      return;
    }
    stdout.writeln('agent_loop: proposing the $what at turn $turn');
    final sent = await runToEnd(
      replyActions(
        drawing: drawing,
        text: text,
        usage: usage,
        replyEndpoint: endpoint,
        signIn: signIn,
        trajectory: started.trajectory,
        turn: turn,
      ),
      Crux.forTheReply(link, turn: turn),
    );
    latestOwn = ProposedForTheReply.at(turn, 0);
    switch (sent) {
      case Done(:final value):
        stdout.writeln('agent_loop: $what sent, in $value request(s)');
      case Failed(:final why):
        stderr.writeln('agent_loop: $what refused: $why');
      case Action():
        throw StateError('runToEnd returned an unresolved Action');
    }
  }

  // Asks the model at the next turn, to answer [after]: a message, or a
  // tool call's result. A reply that calls a tool is said to no one: the
  // history then owes its tool's action.
  Future<void> askTheModel(ObjectId after) async {
    final starting = startingModel(history);
    final model = starting.model;
    if (model == null) {
      stderr.writeln(
        'agent_loop: ERROR not answering ${after.hex}: no model to '
        'call, since ${starting.why}',
      );
      return;
    }
    final given = tools();
    final request = encodeModelInput(trajectoryInput(history, tools: given));
    final requestHash = await recordModelRequestOnTrajectory(
      chain,
      systemPrompt: _systemPrompt(given),
      request: request,
      builtFrom: [for (final e in history) e.hash],
    );
    stdout.writeln('agent_loop: recorded model-request ${requestHash.hex}');

    final turn = nextTurn++;
    latestOwn = ProposedForTheModelCall.at(turn);
    final asked = Program.askTheModel.runOrRefusal<ModelReply>(
      ModelCall(
        signIn: model.signIn,
        model: model.model,
        request: EntryId.parse(requestHash.hex)!,
      ),
      then: (ModelReply reply) => Done(reply),
    );
    final Result<ModelReply> outcome = await asked.next(
      Crux.forTheModelCall(link, turn: turn),
    );
    switch (outcome) {
      case Done(:final value):
        stdout.writeln('agent_loop: model replied: ${value.text}');
        if (readModelReply(value.text) is! AnswerText) return;
        await sayBack(
          turn,
          value.text,
          'answer to ${after.hex}',
          usage: value.usage,
        );
      case Failed(:final why):
        stdout.writeln('agent_loop: model call refused: $why');
        await sayBack(
          turn,
          'The model call was refused: $why',
          'refusal notice',
        );
      case Action():
        // runOrRefusal's own then never returns one: it is called only
        // with the output, never asked to propose a further action.
        throw StateError('runOrRefusal returned an unresolved Action');
    }
  }

  // Proposes [tool]'s action at [place]; its outcome arrives in history.
  Future<void> runTool(ProposedForAnIntent place, OneActionTool tool) async {
    final ProposedForAnIntent(:turn, :intent) = place;
    latestOwn = place;
    stdout.writeln('agent_loop: running tool ${tool.name} at $place');
    await toolAction(tool)
        .next(Crux.forIntent(link, turn: turn, intent: intent));
  }

  // Does whatever the history owes now, if anything.
  Future<void> doOwed() async {
    switch (stepOwed(history, tools: tools(), latestOwn: latestOwn)) {
      case null:
        return;
      case ModelCallOwed(:final after):
        await askTheModel(after);
      case ToolActionOwed(:final place, :final tool):
        await runTool(place, tool);
      case ModelCallsSpent(:final turn):
        await sayBack(
          turn,
          'I stopped after $maxModelCallsPerMessage model calls for this '
              'message without an answer.',
          'notice that its model calls are spent',
        );
    }
  }

  // The backlog is only read, never answered as it arrives: a message in it
  // may already have its answer further on. Once caught up, the loop
  // answers whatever is owed after each event.
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
        latestOwn = last;
        stdout.writeln('agent_loop: caught up at place ${last ?? 'none'}');
        await doOwed();
      case TrajectoryEvent event:
        history.add(event);
        if (!caughtUp) continue;
        await doOwed();
    }
  }
}

final class _Options {
  const _Options({
    required this.logbookRead,
    required this.logbookWrite,
    required this.replyDrawing,
  });

  final String logbookRead;
  final String logbookWrite;

  /// The program that draws a reply as its surface's requests, run through
  /// the airlock's program driver; null sends no replies.
  final Executable? replyDrawing;

  /// Reads `--logbook-read`, `--logbook-write` and, optionally,
  /// `--reply-drawing`.
  static _Options? parse(List<String> args) {
    String? logbookRead;
    String? logbookWrite;
    ProgramName? replyDrawing;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--logbook-read' when i + 1 < args.length:
          logbookRead = args[++i];
        case '--logbook-write' when i + 1 < args.length:
          logbookWrite = args[++i];
        case '--reply-drawing' when i + 1 < args.length:
          replyDrawing = ProgramName.parse(args[++i]);
          if (replyDrawing == null) return null;
        default:
          return null;
      }
    }
    return logbookRead != null && logbookWrite != null
        ? _Options(
            logbookRead: logbookRead,
            logbookWrite: logbookWrite,
            replyDrawing: replyDrawing == null
                ? null
                : Executable(replyDrawing),
          )
        : null;
  }
}
