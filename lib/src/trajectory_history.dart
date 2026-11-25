/// A trajectory's history as the loop actually sees it, live: the user's
/// own messages arrive as `event-admitted-to-mission` entries (the docking
/// station's own kind), never as turns on the loop's chain. Only the
/// loop's own turn-chain entries (still carrying `UserSaid`'s data, since
/// [MessageSaid.node] IS one) are read by [followTrajectory]; this reads
/// both, merged in logbook order.
///
/// A prior agent reply is read from the airlock's outcome of the model call
/// that produced it ([SaidByAgent]), never from a turn: a loop writes no
/// reply turn of its own.
library;

import 'dart:async';
import 'dart:convert' show utf8;

import 'package:is_airlock_api/is_airlock_api.dart'
    show
        ActionProposedByAgentLoop,
        AskTheModel,
        Executable,
        FetchFromWeb,
        MakeWebRequests,
        PlaceInTrajectory,
        ProposedForAnIntent,
        ProposedForTheReply,
        ReadFile,
        ReadFileBytes,
        ReplyToOwnConversation,
        WriteFile,
        outcomeOfProposedActionKind,
        readOutcomeOfProposedAction;
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show
        AddressInExternalSystem,
        DecisionEntryKind,
        EventAdmittedToMission,
        MessageSaid,
        StartsTrajectory,
        decodeDecision;
import 'package:is_conversation_reply_vocabulary/is_conversation_reply_vocabulary.dart'
    show ReplyEndpoint;
import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_flight_rules/is_flight_rules.dart' show FlightRules;
import 'package:is_logbook_client/is_logbook_client.dart'
    show CaughtUp, Entry, Kind, LogbookReader, ObjectId;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show CutOffReply, FinishedReply, ModelReply, ProposedToolCalls, ToolCall;
import 'package:is_effects/is_effects.dart'
    show
        ModelAndSignIn,
        NothingRan,
        Outcome,
        Ran,
        StoppedPartway,
        WebResponse,
        decodeModelReply,
        decodeOutcome,
        decodeWebResponse;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show
        AgentCalledTools,
        AgentSaid,
        ModelTurn,
        ToolAnswered,
        ToolName,
        ToolResult,
        UserSaid;
import 'package:is_shapes/is_shapes.dart' show ActorId, EntryId, TrajectoryId;
import 'package:is_tools_api/is_tools_api.dart' show OneActionTool;

import 'model_request_input.dart' show inputTurnOf;
import 'tool_calls.dart';
import 'turn_envelope.dart';

/// What [followTrajectoryHistory] hands on: each [TrajectoryEvent] in
/// order, and one [CaughtUpWithTrajectory] once the backlog has been read.
sealed class TrajectoryFeedItem {
  const TrajectoryFeedItem();
}

/// The backlog is read: every item before this one had already happened
/// when the loop started; every item after it is live.
final class CaughtUpWithTrajectory extends TrajectoryFeedItem {
  const CaughtUpWithTrajectory();
}

/// One event in a trajectory's history, in the order it actually happened:
/// [SaidByUser] (an admitted message), [SaidByAgent] (the model's reply to
/// a call the loop proposed), [FetchEnded] (a tool's fetch the loop
/// proposed), [ActionProposed] (a proposal this loop wrote) or [TurnOnChain]
/// (a turn the loop itself wrote).
sealed class TrajectoryEvent extends TrajectoryFeedItem {
  const TrajectoryEvent({required this.hash});

  /// The logbook entry this event was read from: what a
  /// [ModelRequestFromPieces.builtFrom] names for it.
  final ObjectId hash;
}

/// A message the docking station admitted, read from its
/// `event-admitted-to-mission` entry, never from a turn: [startsTurn] is
/// whether the turn rule said the agent should answer it, false for
/// something admitted as context only.
final class SaidByUser extends TrajectoryEvent {
  const SaidByUser({
    required super.hash,
    required this.author,
    required this.text,
    required this.startsTurn,
    required this.address,
  });

  final ActorId author;
  final String text;
  final bool startsTurn;

  /// Where this was said, in the external system it came from: a reply to
  /// this turn goes back here.
  final AddressInExternalSystem address;
}

/// The model's reply to a call this loop proposed, read from the airlock's
/// outcome entry for it: [hash] is that outcome entry, which is what the
/// model's later requests were built from, and [proposed] the call it
/// answers. [reply] says whether the model finished or was cut off, and
/// what the call used when the driver could tell.
final class SaidByAgent extends TrajectoryEvent {
  const SaidByAgent({
    required super.hash,
    required this.proposed,
    required this.reply,
  });

  final ObjectId proposed;
  final ModelReply reply;

  String get text => reply.text;
}

/// The airlock's outcome for a model call this loop proposed, [proposed],
/// when the model did not run: the call has ended, with nothing said.
final class ModelCallRefused extends TrajectoryEvent {
  const ModelCallRefused({required super.hash, required this.proposed});

  final ObjectId proposed;
}

/// The airlock's outcome for a tool's fetch this loop proposed, [proposed],
/// as the model hears it: [result] ([fetchResult]).
final class FetchEnded extends TrajectoryEvent {
  const FetchEnded({
    required super.hash,
    required this.proposed,
    required this.result,
  });

  final ObjectId proposed;
  final ToolResult result;
}

/// The program a proposal runs, as far as the loop tells them apart.
enum ProposedProgram { askTheModel, fetchFromWeb, other }

/// An action this loop proposed: [place] is the place it named, and
/// [program] what it runs. A replayed history needs both: whether a message
/// was already answered, whether a tool call was already run, and which
/// turn the next proposal starts.
final class ActionProposed extends TrajectoryEvent {
  const ActionProposed({
    required super.hash,
    required this.place,
    required this.program,
  });

  final PlaceInTrajectory place;
  final ProposedProgram program;

  bool get asksTheModel => program == ProposedProgram.askTheModel;
}

/// The admission that started this trajectory, and the [rules] it started
/// under: [FlightRules.startingModel] is the model and sign-in its loop's
/// calls go out as.
final class TrajectoryStarted extends TrajectoryEvent {
  const TrajectoryStarted({
    required super.hash,
    required this.rules,
    required this.replyEndpoint,
  });

  final FlightRules rules;

  /// The trajectory's id: the hash of the admission that started it, never
  /// the loop's own chain root, which is its loop user's assignment.
  TrajectoryId get trajectory => TrajectoryId.parse(hash.hex)!;

  /// Where replies to the event that started the trajectory go, as the
  /// admission recorded it beside [rules]: the one value the airlock's
  /// reply grants are decided against. Null when the module that
  /// translated the event can't name one, and the loop then sends no reply.
  final ReplyEndpoint? replyEndpoint;
}

/// The admission that started this trajectory carried rules that do not
/// read as [FlightRules], because [why]: the loop has no model to call.
final class TrajectoryRulesUnreadable extends TrajectoryEvent {
  const TrajectoryRulesUnreadable({required super.hash, required this.why});

  final String why;
}

/// An entry the loop itself wrote on its own turn chain.
final class TurnOnChain extends TrajectoryEvent {
  const TurnOnChain({required super.hash, required this.turn});

  final TurnEnvelope turn;
}

final _proposedKind = Kind.parse(ActionProposedByAgentLoop.kind)!;
final _outcomeKind = Kind.parse(outcomeOfProposedActionKind)!;

/// Every event on [chainRoot]'s trajectory, live, in logbook order: the
/// loop's own turns (by the same chain-membership rule [followTrajectory]
/// uses) and every `MessageSaid` the docking station admitted to this
/// trajectory — trusting the feed's own scoping for the latter, since an
/// admission is never chained onto the loop's turns at all. An admission
/// whose reading is not something said (a join, a change) is skipped: this
/// loop has nothing to render for it yet.
///
/// The relay's raw events are not subscribed to: what the loop needs of an
/// event is in its admission, and a raw event's kind is its source's.
///
/// The loop's own proposals arrive too, each as an [ActionProposed], and
/// the airlock's outcome of each: an outcome answering a proposal that
/// asked the model, if the model ran, becomes a [SaidByAgent]. Every other
/// outcome (a refused call, a web request) is skipped. A proposal the
/// airlock could not read as one is skipped too.
///
/// Built with [Stream.expand] rather than `async*`, for the same reason as
/// [followTrajectory]: `expand` passes a cancel straight through to
/// [LogbookReader.subscribe], which an `async*` wrapper would not.
Stream<TrajectoryFeedItem> followTrajectoryHistory(
  LogbookReader reader, {
  required Kind turnKind,
  required ObjectId chainRoot,
}) {
  final onChain = <ObjectId>{chainRoot};
  final modelCalls = <EntryId>{};
  final fetches = <EntryId>{};
  final kinds = {
    turnKind,
    DecisionEntryKind.eventAdmittedToMission,
    _proposedKind,
    _outcomeKind,
  };
  return reader.subscribe(kinds: kinds).expand((item) {
    final Entry entry;
    switch (item) {
      case CaughtUp():
        return const [CaughtUpWithTrajectory()];
      case Entry():
        entry = item;
    }
    if (entry.kind == _proposedKind) {
      if (ActionProposedByAgentLoop.read(_text(entry.body))
          case ActionProposedByAgentLoop(:final place, :final program)) {
        final id = EntryId.parse(entry.id.hex)!;
        final proposed = switch (program) {
          AskTheModel() => ProposedProgram.askTheModel,
          FetchFromWeb() => ProposedProgram.fetchFromWeb,
          ReadFile() ||
          ReadFileBytes() ||
          WriteFile() ||
          Executable() ||
          MakeWebRequests() ||
          ReplyToOwnConversation() => ProposedProgram.other,
        };
        switch (proposed) {
          case ProposedProgram.askTheModel:
            modelCalls.add(id);
          case ProposedProgram.fetchFromWeb:
            fetches.add(id);
          case ProposedProgram.other:
        }
        return [
          ActionProposed(hash: entry.id, place: place, program: proposed),
        ];
      }
      return const [];
    }
    if (entry.kind == _outcomeKind) {
      if (_fetchEndIn(entry.body, fetches) case (
        :final proposed,
        :final result,
      )) {
        return [FetchEnded(hash: entry.id, proposed: proposed, result: result)];
      }
      return switch (_modelCallEndIn(entry.body, modelCalls)) {
        null => const [],
        (:final proposed, reply: final reply?) => [
          SaidByAgent(hash: entry.id, proposed: proposed, reply: reply),
        ],
        (:final proposed, reply: null) => [
          ModelCallRefused(hash: entry.id, proposed: proposed),
        ],
      };
    }
    if (entry.kind == turnKind) {
      final belongs =
          entry.previous != null && onChain.contains(entry.previous);
      if (!belongs) return const [];
      onChain.add(entry.id);
      return [
        TurnOnChain(hash: entry.id, turn: TurnEnvelope.decode(entry.body)),
      ];
    }
    final decision = decodeDecision(entry.kind, entry.body);
    if (decision is! EventAdmittedToMission) return const [];
    return [
      if (decision case EventAdmittedToMission(
        placement: StartsTrajectory(),
        rules: final rules?,
        :final replyEndpoint,
      ))
        _startedUnder(entry.id, rules, replyEndpoint),
      if (decision case EventAdmittedToMission(
        translatedEvent: MessageSaid(
          :final node,
          :final addressInExternalSystem,
        ),
        :final startsTurn,
      ))
        SaidByUser(
          hash: entry.id,
          author: node.author,
          text: node.text,
          startsTurn: startsTurn ?? false,
          address: addressInExternalSystem,
        ),
    ];
  });
}

/// The admission [hash] started this trajectory under [rules], with replies
/// going to [replyEndpoint]: the rules read once, strictly, as
/// [FlightRules].
TrajectoryEvent _startedUnder(
  ObjectId hash,
  JsonObject rules,
  ReplyEndpoint? replyEndpoint,
) {
  try {
    return TrajectoryStarted(
      hash: hash,
      rules: FlightRules.fromJson(rules),
      replyEndpoint: replyEndpoint,
    );
  } on FormatException catch (e) {
    return TrajectoryRulesUnreadable(hash: hash, why: e.message);
  }
}

/// The end of one of [modelCalls] in [body], an outcome entry's: the call
/// it answers, and the model's reply, or null when the model did not run.
/// Null for an outcome of anything else. An outcome whose result does not
/// decode ends its call too, with no reply.
({ObjectId proposed, ModelReply? reply})? _modelCallEndIn(
  List<int> body,
  Set<EntryId> modelCalls,
) {
  final outcome = readOutcomeOfProposedAction(_text(body));
  if (outcome == null || !modelCalls.contains(outcome.proposed)) return null;
  final proposed = ObjectId.parse(outcome.proposed.hex)!;
  try {
    return (
      proposed: proposed,
      reply: switch (decodeOutcome(outcome.result, decodeModelReply)) {
        Ran(:final output) => output,
        NothingRan() || StoppedPartway() => null,
      },
    );
  } on FormatException {
    return (proposed: proposed, reply: null);
  }
}

/// The end of one of [fetches] in [body], an outcome entry's: the fetch it
/// answers, and what the model hears about it. Null for an outcome of
/// anything else.
({ObjectId proposed, ToolResult result})? _fetchEndIn(
  List<int> body,
  Set<EntryId> fetches,
) {
  final outcome = readOutcomeOfProposedAction(_text(body));
  if (outcome == null || !fetches.contains(outcome.proposed)) return null;
  return (
    proposed: ObjectId.parse(outcome.proposed.hex)!,
    result: fetchResult(_decodedFetch(outcome.result)),
  );
}

/// [result] read as a fetch's outcome, or null when it doesn't decode.
Outcome<WebResponse>? _decodedFetch(Object? result) {
  try {
    return decodeOutcome(result, decodeWebResponse);
  } on FormatException {
    return null;
  }
}

/// An entry's body as the text the airlock's readers take; a body that is
/// not UTF-8 reads as text they then refuse, rather than throwing here.
String _text(List<int> body) => utf8.decode(body, allowMalformed: true);

/// [history], oldest first, as a model request's turns: one per message
/// and reply. A reply goes where the call it answers was proposed, not
/// where its outcome arrived, so a message admitted while the model was
/// answering comes after that answer, as the model saw it.
/// [TurnOnChain] goes through [inputTurnOf]'s own node-shape cases; since
/// ReplyText turns are dead and no `UserSaid` ever arrives this way any
/// more (it arrives as [SaidByUser] instead), nothing currently reaches
/// this case — kept for whatever the loop's own chain ends up carrying.
/// Throws [FormatException] for a [TurnOnChain] whose node shape it doesn't
/// know.
///
/// A reply that calls tools is followed by one answer per call, in the
/// order it made them: its fetch's result, why it can't run, or that it was
/// never run. [tools] are the trajectory's, by name.
List<ModelTurn> trajectoryInput(
  List<TrajectoryEvent> history, {
  required Map<ToolName, OneActionTool> tools,
}) {
  final replies = {
    for (final event in history)
      if (event case SaidByAgent(:final proposed, :final reply))
        proposed: reply,
  };
  return [
    for (final event in history)
      ...switch (event) {
        SaidByUser(:final text) => [UserSaid(text)],
        ActionProposed(asksTheModel: true, :final hash, :final place) => [
          if (replies[hash] case final reply?)
            ...switch (reply) {
              FinishedReply(:final text) => [AgentSaid(text)],
              CutOffReply(:final text) => [AgentSaid('$text\n\n$_cutOffNote')],
              ProposedToolCalls(
                :final text,
                :final calls,
                :final continuation,
              ) =>
                [
                  AgentCalledTools(
                    text: text,
                    calls: calls,
                    continuation: continuation,
                  ),
                  for (final (i, call) in calls.indexed)
                    ToolAnswered(
                      callId: call.id,
                      result: _answerTo(history, place.turn, i, call, tools),
                    ),
                ],
            },
        ],
        TurnOnChain(:final turn) => [inputTurnOf(turn)],
        ActionProposed() ||
        SaidByAgent() ||
        ModelCallRefused() ||
        FetchEnded() ||
        TrajectoryStarted() ||
        TrajectoryRulesUnreadable() => const [],
      },
  ];
}

/// What the model hears about [call], the [index]th call of [turn]'s reply,
/// read against [tools]: why it can't run, its fetch's result once ended,
/// or [notRun].
ToolResult _answerTo(
  List<TrajectoryEvent> history,
  int turn,
  int index,
  ToolCall call,
  Map<ToolName, OneActionTool> tools,
) => switch (toolCalled(call, tools)) {
  CallCannotRun(:final result) => result,
  CallRuns() => switch (_fetchAt(history, _callPlace(turn, index))) {
    null => notRun,
    final fetch => _fetchEnd(history, fetch)?.result ?? notRun,
  },
};

/// The calls [reply] makes, or null when it makes none.
List<ToolCall>? _callsIn(ModelReply reply) => switch (reply) {
  ProposedToolCalls(:final calls) => calls,
  FinishedReply() || CutOffReply() => null,
};

/// Where the [index]th call of [turn]'s reply proposes its tool's one
/// action: each call is its own intent, and a one-action tool's action is 0.
ProposedForAnIntent _callPlace(int turn, int index) =>
    ProposedForAnIntent.at(turn, index, 0);

/// The fetch this loop proposed at [place] in [history], if any.
ActionProposed? _fetchAt(
  List<TrajectoryEvent> history,
  PlaceInTrajectory place,
) => history
    .whereType<ActionProposed>()
    .where((e) => e.place == place && e.program == ProposedProgram.fetchFromWeb)
    .firstOrNull;

/// [fetch]'s end in [history], if it has ended.
FetchEnded? _fetchEnd(List<TrajectoryEvent> history, ActionProposed fetch) =>
    history
        .whereType<FetchEnded>()
        .where((e) => e.proposed == fetch.hash)
        .firstOrNull;

/// Follows a cut-off reply's text in the model's own history, so it knows
/// that reply stopped short rather than reading it as finished.
const _cutOffNote = '(This reply was cut off before it finished.)';

/// The model and sign-in [history]'s trajectory started under: from the
/// admission that started it, or why there is none. A loop asks the model
/// nothing without one.
({ModelAndSignIn? model, String? why}) startingModel(
  List<TrajectoryEvent> history,
) {
  for (final event in history) {
    switch (event) {
      case TrajectoryStarted(:final rules):
        return (model: rules.startingModel, why: null);
      case TrajectoryRulesUnreadable(:final why):
        return (model: null, why: 'its rules do not read: $why');
      case SaidByUser() ||
          SaidByAgent() ||
          ModelCallRefused() ||
          FetchEnded() ||
          ActionProposed() ||
          TurnOnChain():
        continue;
    }
  }
  return (model: null, why: 'no admission started it under rules');
}

/// The message a loop started on [history] still owes an answer: the
/// latest one that starts a turn, unless this loop has proposed a model
/// call after it. Null when every such message was answered, or there is
/// none. Only the latest counts: one answer, built from the whole history,
/// covers any earlier ones that arrived while the loop was down.
SaidByUser? unansweredTurn(List<TrajectoryEvent> history) {
  for (final event in history.reversed) {
    switch (event) {
      case ActionProposed(asksTheModel: true):
        return null;
      case SaidByUser(startsTurn: true):
        return event;
      case SaidByUser() ||
          SaidByAgent() ||
          ModelCallRefused() ||
          FetchEnded() ||
          ActionProposed() ||
          TurnOnChain() ||
          TrajectoryStarted() ||
          TrajectoryRulesUnreadable():
        continue;
    }
  }
  return null;
}

/// The latest entry this loop wrote on its own chain that [history] holds:
/// a proposal or a turn. A restarted loop's chain resumes after it.
ObjectId? lastOwnEntry(List<TrajectoryEvent> history) => [
  for (final event in history)
    if (event is ActionProposed || event is TurnOnChain) event.hash,
].lastOrNull;

/// Whether every model call and fetch this loop has proposed has ended in
/// [history], its proposal and its outcome both read: [latestOwn] is the
/// latest place the loop itself has proposed at, so it counts even before
/// its proposal arrives. Until then the loop does nothing next, since a
/// reply or a result still on its way decides what that is.
bool actionsSettled(
  List<TrajectoryEvent> history, {
  required PlaceInTrajectory? latestOwn,
}) {
  final awaited = [
    for (final event in history)
      if (event case ActionProposed(
        program: ProposedProgram.askTheModel || ProposedProgram.fetchFromWeb,
      ))
        event,
  ];
  final ended = {
    for (final event in history)
      if (event
          case SaidByAgent(:final proposed) ||
              ModelCallRefused(:final proposed) ||
              FetchEnded(:final proposed))
        proposed,
  };
  return (latestOwn == null ||
          history.any((e) => e is ActionProposed && e.place == latestOwn)) &&
      awaited.every((call) => ended.contains(call.hash));
}

/// How many model calls one message may cause, the call answering it
/// included, before the loop stops running tools for it and says so.
const maxModelCallsPerMessage = 8;

/// What a loop owes next on [history], whose trajectory gives it [tools]:
/// null while anything it proposed, up to [latestOwn], is still under way,
/// and when nothing is owed.
///
/// The calls the latest reply makes are run first, one at a time in the
/// order it made them, so their results are in the request that follows,
/// even when a message arrived meanwhile. Then a message still unanswered
/// is owed a model call, and so are the calls' results, until the message
/// has caused [maxModelCallsPerMessage] calls.
StepOwed? stepOwed(
  List<TrajectoryEvent> history, {
  required Map<ToolName, OneActionTool> tools,
  required PlaceInTrajectory? latestOwn,
}) {
  if (!actionsSettled(history, latestOwn: latestOwn)) return null;
  final call = history
      .whereType<ActionProposed>()
      .where((e) => e.asksTheModel)
      .lastOrNull;
  final reply = call == null
      ? null
      : history
            .whereType<SaidByAgent>()
            .where((e) => e.proposed == call.hash)
            .firstOrNull;
  final calls = reply == null ? null : _callsIn(reply.reply);
  final spent = _modelCallsSinceMessage(history) >= maxModelCallsPerMessage;
  if (call != null && calls != null && !spent) {
    for (final (i, toolCall) in calls.indexed) {
      if (toolCalled(toolCall, tools) case CallRuns(:final tool)) {
        final place = _callPlace(call.place.turn, i);
        if (_fetchAt(history, place) == null) {
          return ToolActionOwed(place: place, tool: tool);
        }
      }
    }
  }
  if (unansweredTurn(history) case final message?) {
    return ModelCallOwed(after: message.hash);
  }
  if (call == null || reply == null || calls == null) return null;
  if (spent) {
    final replied = history.whereType<ActionProposed>().any(
      (e) => e.place is ProposedForTheReply && e.place.turn == call.place.turn,
    );
    return replied ? null : ModelCallsSpent(turn: call.place.turn);
  }
  return ModelCallOwed(after: reply.hash);
}

/// How many model calls this loop has proposed since the latest message
/// that starts a turn.
int _modelCallsSinceMessage(List<TrajectoryEvent> history) {
  var calls = 0;
  for (final event in history.reversed) {
    if (event case SaidByUser(startsTurn: true)) break;
    if (event case ActionProposed(asksTheModel: true)) calls++;
  }
  return calls;
}

/// What [stepOwed] says a loop does next.
sealed class StepOwed {
  const StepOwed();
}

/// Ask the model, at the loop's next turn: what it last said or was told,
/// the entry [after], is the model's to answer.
final class ModelCallOwed extends StepOwed {
  const ModelCallOwed({required this.after});

  final ObjectId after;
}

/// Propose [tool]'s action at [place]: a call in the latest reply named it.
final class ToolActionOwed extends StepOwed {
  const ToolActionOwed({required this.place, required this.tool});

  final ProposedForAnIntent place;
  final OneActionTool tool;
}

/// The latest message has caused [maxModelCallsPerMessage] model calls, and
/// [turn]'s reply still calls tools: say so, as [turn]'s reply, and ask
/// nothing more until another message arrives.
final class ModelCallsSpent extends StepOwed {
  const ModelCallsSpent({required this.turn});

  final int turn;
}

/// The latest place this loop has proposed at in [history], or null for
/// none: a restarted loop's next turn goes after it, never reusing a place.
PlaceInTrajectory? lastPlace(List<TrajectoryEvent> history) =>
    [
      for (final event in history)
        if (event case ActionProposed(:final place)) place,
    ].fold(
      null,
      (latest, place) =>
          latest == null || place.compareTo(latest) > 0 ? place : latest,
    );
