/// The loop's entry point: run as `agent-loop@<loop-user>`, one per
/// trajectory, with no arguments beyond the two logbook sockets — the loop
/// itself gets no sign-in and no network of its own; the airlock makes the
/// model call, under the model and sign-in the trajectory started under
/// (its starting admission's rules, [startingModel]). It finds
/// its own assignment in the logbook rather than being told its trajectory
/// (infra's polkit can start only named template units, so loop_launcher
/// can pass no per-trajectory argument), follows its trajectory's history
/// live (the docking station's admissions and its own chain, merged),
/// and, whenever the turn rule says the agent should answer, records a
/// model request and proposes [AskTheModel] through the logbook, naming it.
///
/// Each model call is one step, counted from 0: the call through
/// [ProposesAtNextPlace.forTheModelCall], then, when it answers, its reply
/// through [ProposesAtNextPlace.forTheReply] at the same step. A
/// restarted loop's next step follows the latest place in its history.
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
/// When the model call is refused, the step's reply says why, so its sender
/// decides what to do. A refused reply is only logged: the way back to the
/// person is what failed.
///
/// The model is offered the tools the trajectory's rules give it, inside
/// the request ([offeredTools]). A reply that calls tools ends its step
/// with each call's action, one at a time, each call at its own intent
/// ([toolAction]); the next step asks the model again with every call's
/// result. What to do next is always read from the history ([stepOwed]),
/// so a restarted loop picks up its calls where it left off.
///
/// When a final reply leaves less than `--compact-margin` tokens of the
/// model's context window, the loop asks the model for a summary as a step
/// of its own, once nothing else is owed, and later requests send the
/// summary in place of what it covers (lib/src/history_compaction.dart).
library;

import 'dart:io';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_effects/is_effects.dart' show ProgramName;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show
        CutOffReply,
        FinishedReply,
        ModelReply,
        ModelRequest,
        ModelUsage,
        ProposedToolCalls,
        ToolName;
import 'package:is_airlock_api/is_airlock_api.dart'
    show
        Action,
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
    show LogbookReader, ObjectId;
import 'package:is_shapes/is_shapes.dart' show EntryId;
import 'package:is_tools_api/is_tools_api.dart' show OneActionTool;

/// A fixed, labelled placeholder for the system prompt: enough to exercise
/// recording for real, not what a demo's system prompt will actually say.
/// The tools travel in the request, not here.
const _placeholderSystemPrompt =
    'You are the agent in this conversation. Reply in plain text.';

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options == null) {
    stderr.writeln(
      'usage: agent_loop --logbook-read <socket> --logbook-write <socket> '
      '[--reply-drawing <program>] [--compact-margin <tokens>]',
    );
    exitCode = LoopExit.usage.code;
    return;
  }
  try {
    await _run(options);
  } on Object catch (error, trace) {
    final ending = LoopExit.forFailure(error);
    stderr.writeln(
      'agent_loop: exiting ${ending.name} (${ending.code}): $error',
    );
    if (ending == LoopExit.software) stderr.writeln(trace);
    // The logbook subscriptions would keep the process alive past main.
    exit(ending.code);
  }
}

/// Follows the trajectory and answers it until a feed ends or something
/// fails: it never returns, only throws.
Future<Never> _run(_Options options) async {
  final loopUser = Process.runSync('id', ['-un']).stdout.toString().trim();
  stdout.writeln(
    'agent_loop: ready loopUser=$loopUser '
    'read=${options.logbookRead} write=${options.logbookWrite} '
    'replyDrawing=${options.replyDrawing?.name ?? 'none'}',
  );

  final reader = LogbookReader(options.logbookRead);
  final root = await findTrajectoryRoot(reader, loopUser: loopUser);
  stdout.writeln('agent_loop: assigned root=${root.hex}');

  final writer = LogbookWriter(options.logbookWrite);
  final chain = TrajectoryChain.resumed(writer: writer, root: root);
  final link = TrajectoryProposalLink(
    chain: chain,
    returned: followResults(reader),
  );

  final history = <TrajectoryEvent>[];
  var nextStep = 0;
  // The latest place this loop proposed at: until its proposal is in
  // history, nothing next is owed.
  PlaceInTrajectory? latestOwn;

  Map<ToolName, OneActionTool> tools() =>
      history.whereType<TrajectoryStarted>().firstOrNull?.rules.givenTools ??
      const {};

  // Says [text] back to whoever started the trajectory, as [step]'s reply,
  // footered with [usage] when the model call reported it. A refused reply
  // is only logged: there is no other way back.
  Future<void> sayBack(
    int step,
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
    final address = replyAddressFor(endpoint);
    if (address == null) {
      stderr.writeln(
        'agent_loop: $what not sent: this trajectory replies in a Slack '
        "conversation, which the loop can't send to yet",
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
    stdout.writeln('agent_loop: proposing the $what at step $step');
    final sent = await runToEnd(
      replyActions(
        drawing: drawing,
        text: text,
        usage: usage,
        replyEndpoint: address,
        signIn: signIn,
        trajectory: started.trajectory,
        step: step,
      ),
      ProposesAtNextPlace.forTheReply(link, step: step),
    );
    latestOwn = ProposedForTheReply.at(step, 0);
    switch (sent) {
      case Done(:final value):
        stdout.writeln('agent_loop: $what sent, in $value request(s)');
      case Failed(:final why):
        stderr.writeln('agent_loop: $what refused: $why');
      case Action():
        throw StateError('runToEnd returned an unresolved Action');
    }
  }

  // Asks the model at the next step, to answer [after]: a message, or a
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
    final window = requestWindow(history);
    final request = ModelRequest(
      tools: offeredTools(given.values),
      turns: trajectoryInput(window, tools: given),
    ).encode();
    final requestHash = await recordModelRequestOnTrajectory(
      chain,
      systemPrompt: _placeholderSystemPrompt,
      request: request,
      builtFrom: [for (final e in window) e.hash],
    );
    stdout.writeln('agent_loop: recorded model-request ${requestHash.hex}');

    final step = nextStep++;
    latestOwn = ProposedForTheModelCall.at(step);
    final asked = Program.askTheModel.runOrFail<ModelReply>(
      ModelCall(
        signIn: model.signIn,
        model: model.model,
        request: EntryId.parse(requestHash.hex)!,
      ),
      then: (ModelReply reply) => Done(reply),
    );
    final Result<ModelReply> outcome = await asked.next(
      ProposesAtNextPlace.forTheModelCall(link, step: step),
    );
    switch (outcome) {
      case Done(:final value):
        stdout.writeln('agent_loop: model replied: ${value.text}');
        // Calls are run, and their results asked about, before anyone is
        // answered.
        if (value is ProposedToolCalls) return;
        await sayBack(
          step,
          value.text,
          'answer to ${after.hex}',
          usage: value.usage,
        );
      case Failed(:final why):
        stdout.writeln('agent_loop: model call failed: $why');
        await sayBack(step, 'The model call failed: $why', 'failure notice');
      case Action():
        // runOrFail's own then never returns one: it is called only with
        // the output, never asked to propose a further action.
        throw StateError('runOrFail returned an unresolved Action');
    }
  }

  // Asks the model to summarize the window up to [upTo], as a step of its
  // own: at [markedStep] when its marker is already written, otherwise at
  // the next step, writing the marker first. Offers the same tools as the
  // answer did, so the provider's cache of that prefix carries over. Its
  // outcome arrives in history as a [SummaryByAgent], which [requestWindow]
  // puts in place of what it covers; a refused, cut-off or tool-calling one
  // leaves the window whole.
  Future<void> summarize(ObjectId upTo, int? markedStep) async {
    final model = startingModel(history).model;
    final given = tools();
    final summary = summaryRequest(history, upTo, tools: given);
    if (model == null || summary == null) {
      stderr.writeln(
        'agent_loop: not summarizing up to ${upTo.hex}: '
        '${model == null ? 'no model to call' : 'it is not in the window'}',
      );
      return;
    }
    final step = markedStep ?? nextStep;
    nextStep = step + 1;
    latestOwn = ProposedForTheModelCall.at(step);
    if (markedStep == null) {
      await chain.appendEntry(
        KindTheLoopWrites.historySummaryAsked,
        HistorySummaryAsked(step: step, upTo: upTo).encode(),
      );
    }
    final requestHash = await recordModelRequestOnTrajectory(
      chain,
      systemPrompt: _placeholderSystemPrompt,
      request: ModelRequest(
        tools: offeredTools(given.values),
        turns: summary.input,
      ).encode(),
      builtFrom: [for (final e in summary.covered) e.hash],
    );
    stdout.writeln(
      'agent_loop: summarizing up to ${upTo.hex} at step $step, '
      'model-request ${requestHash.hex}',
    );
    final asked = Program.askTheModel.runOrFail<ModelReply>(
      ModelCall(
        signIn: model.signIn,
        model: model.model,
        request: EntryId.parse(requestHash.hex)!,
      ),
      then: (ModelReply reply) => Done(reply),
    );
    switch (await asked.next(
      ProposesAtNextPlace.forTheModelCall(link, step: step),
    )) {
      case Done(value: FinishedReply()):
        stdout.writeln('agent_loop: summarized');
      case Done(value: CutOffReply() || ProposedToolCalls()):
        stderr.writeln('agent_loop: summary did not finish, not used');
      case Failed(:final why):
        stderr.writeln('agent_loop: summary call failed: $why');
      case Action():
        throw StateError('runOrFail returned an unresolved Action');
    }
  }

  // Proposes [tool]'s action at [place]; its outcome arrives in history.
  Future<void> runTool(ProposedForAnIntent place, OneActionTool tool) async {
    final ProposedForAnIntent(:step, :intent) = place;
    latestOwn = place;
    stdout.writeln('agent_loop: running tool ${tool.name} at $place');
    await toolAction(tool)
        .next(ProposesAtNextPlace.forIntent(link, step: step, intent: intent));
  }

  // Does whatever the history owes now, if anything.
  Future<void> doOwed() async {
    switch (stepOwed(
      history,
      tools: tools(),
      latestOwn: latestOwn,
      compactMargin: options.compactMargin,
    )) {
      case null:
        return;
      case ModelCallOwed(:final after):
        await askTheModel(after);
      case ToolActionOwed(:final place, :final tool):
        await runTool(place, tool);
      case ModelCallsSpent(:final step):
        await sayBack(
          step,
          'I stopped after $maxModelCallsPerMessage model calls for this '
              'message without an answer.',
          'notice that its model calls are spent',
        );
      case SummaryOwed(:final upTo, :final step):
        await summarize(upTo, step);
    }
  }

  // The backlog is only read, never answered as it arrives: a message in it
  // may already have its answer further on. Once caught up, the loop
  // answers whatever is owed after each event.
  Future<Never> follow() async {
    var caughtUp = false;
    await for (final item in followTrajectoryHistory(reader, chainRoot: root)) {
      switch (item) {
        case CaughtUpWithTrajectory():
          if (caughtUp) continue;
          caughtUp = true;
          if (lastOwnEntry(history) case final lastOwn?) {
            chain.resumeAfter(lastOwn);
          }
          final last = lastPlace(history);
          nextStep = (last?.step ?? -1) + 1;
          latestOwn = last;
          stdout.writeln('agent_loop: caught up at place ${last ?? 'none'}');
          await doOwed();
        case TrajectoryEvent event:
          history.add(event);
          if (!caughtUp) continue;
          await doOwed();
      }
    }
    throw const FeedEnded("the trajectory's history");
  }

  // The results can end while the history waits on its next event.
  return Future.any([follow(), link.ended]);
}

/// The context, in tokens, a final reply may leave before the loop
/// summarizes: room for the summary call's own reply, the next message and
/// its answer.
const _defaultCompactMargin = 40000;

final class _Options {
  const _Options({
    required this.logbookRead,
    required this.logbookWrite,
    required this.replyDrawing,
    required this.compactMargin,
  });

  final String logbookRead;
  final String logbookWrite;

  /// See [_defaultCompactMargin].
  final int compactMargin;

  /// The program that draws a reply as its surface's requests, run through
  /// the airlock's program driver; null sends no replies.
  final Executable? replyDrawing;

  /// Reads `--logbook-read`, `--logbook-write` and, optionally,
  /// `--reply-drawing` and `--compact-margin`.
  static _Options? parse(List<String> args) {
    String? logbookRead;
    String? logbookWrite;
    ProgramName? replyDrawing;
    var compactMargin = _defaultCompactMargin;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--compact-margin' when i + 1 < args.length:
          final margin = int.tryParse(args[++i]);
          if (margin == null || margin < 0) return null;
          compactMargin = margin;
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
            compactMargin: compactMargin,
          )
        : null;
  }
}
