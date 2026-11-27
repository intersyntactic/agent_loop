/// A trajectory's history as the loop actually sees it, live: the user's
/// own messages arrive as `event-admitted-to-mission` entries (the docking
/// station's own kind), never on the loop's chain; the loop's own entries,
/// its proposals and summary markers, are read off its chain; this reads
/// both, merged in logbook order.
///
/// A prior agent reply is read from the airlock's outcome of the model call
/// that produced it ([SaidByAgent]): a loop writes no reply of its own.
///
/// A summary call (lib/src/history_compaction.dart) is a step of its own:
/// its [HistorySummaryAsked] marker arrives as [SummaryAsked], its proposal
/// as an [ActionProposed] for [ProposedProgram.askTheModelForASummary], and
/// its reply as a [SummaryByAgent], never a [SaidByAgent].
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
        ProposedForTheModelCall,
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
    show
        CalledToolName,
        CutOffReply,
        FinishedReply,
        ModelReply,
        ProposedToolCalls,
        ToolCall,
        ToolFailed,
        ToolRan,
        ToolRefused;
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

import 'history_compaction.dart'
    show HistorySummaryAsked, replyOverTheLine, requestWindow;
import 'kind_the_loop_writes.dart';
import 'tool_calls.dart';

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
/// proposed), [ActionProposed] (a proposal this loop wrote) or
/// [SummaryAsked] (a summary marker this loop wrote), among others.
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

/// The summary the model gave in a summary call, [proposed], which a
/// [SummaryAsked] marked first: [hash] is the airlock's outcome entry for
/// it, and [upTo] the last event it covers. Never part of the conversation
/// itself; what a request shows of it is [requestWindow]'s to decide.
final class SummaryByAgent extends TrajectoryEvent {
  const SummaryByAgent({
    required super.hash,
    required this.proposed,
    required this.reply,
    required this.upTo,
  });

  final ObjectId proposed;
  final ModelReply reply;
  final ObjectId upTo;
}

/// A [HistorySummaryAsked] marker, read back off the loop's own chain.
final class SummaryAsked extends TrajectoryEvent {
  const SummaryAsked({required super.hash, required this.asked});

  final HistorySummaryAsked asked;
}

/// The program a proposal runs, as far as the loop tells them apart: a
/// model call is either answering the conversation or summarizing it.
enum ProposedProgram {
  askTheModel,
  askTheModelForASummary,
  fetchFromWeb,
  other,
}

/// An action this loop proposed: [place] is the place it named, and
/// [program] what it runs. A replayed history needs both: whether a message
/// was already answered, whether a tool call was already run, and which
/// step the next proposal starts.
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

final _proposedKind = KindTheLoopWrites.actionProposed.kind;
final _summaryAskedKind = KindTheLoopWrites.historySummaryAsked.kind;
final _outcomeKind = Kind.parse(outcomeOfProposedActionKind)!;

/// Every event on [chainRoot]'s trajectory, live, in logbook order: the
/// loop's own summary markers (an entry belongs to the chain when its
/// `previous` is already on it) and proposals, and every `MessageSaid` the
/// docking station admitted to this trajectory — trusting the feed's own
/// scoping for the latter, since an admission is never chained onto the
/// loop's entries at all. An admission
/// whose reading is not something said (a join, a change) is skipped: this
/// loop has nothing to render for it yet.
///
/// The relay's raw events are not subscribed to: what the loop needs of an
/// event is in its admission, and a raw event's kind is its source's.
///
/// The loop's own proposals arrive too, each as an [ActionProposed], and
/// the airlock's outcome of each: an outcome answering a proposal that
/// asked the model, if the model ran, becomes a [SaidByAgent], or a
/// [SummaryByAgent] when a [HistorySummaryAsked] marker named its step
/// first. A proposal the airlock could not read as one is skipped.
///
/// Built with [Stream.expand] rather than `async*`: an `async*` generator's
/// own cancel waits for its next yield, which never comes while a live
/// subscription is idle; `expand` passes a cancel straight through to
/// [LogbookReader.subscribe].
Stream<TrajectoryFeedItem> followTrajectoryHistory(
  LogbookReader reader, {
  required ObjectId chainRoot,
}) {
  final onChain = <ObjectId>{chainRoot};
  // Each model call proposed, to the last event it summarizes; null for an
  // answer.
  final modelCalls = <EntryId, ObjectId?>{};
  final fetches = <EntryId>{};
  // Each summary marker's step, to the last event it summarizes.
  final summariesAsked = <int, ObjectId>{};
  final kinds = {
    _summaryAskedKind,
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
      // A proposal is written on the loop's own chain, so a turn written
      // after it, such as a summary marker, follows it.
      onChain.add(entry.id);
      if (ActionProposedByAgentLoop.read(_text(entry.body))
          case ActionProposedByAgentLoop(:final place, :final program)) {
        final id = EntryId.parse(entry.id.hex)!;
        final upTo = place is ProposedForTheModelCall
            ? summariesAsked[place.step]
            : null;
        final proposed = switch (program) {
          AskTheModel() when upTo != null =>
            ProposedProgram.askTheModelForASummary,
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
          case ProposedProgram.askTheModel ||
              ProposedProgram.askTheModelForASummary:
            modelCalls[id] = upTo;
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
        (:final proposed, reply: final reply?, upTo: null) => [
          SaidByAgent(hash: entry.id, proposed: proposed, reply: reply),
        ],
        (:final proposed, reply: final reply?, :final upTo?) => [
          SummaryByAgent(
            hash: entry.id,
            proposed: proposed,
            reply: reply,
            upTo: upTo,
          ),
        ],
        (:final proposed, reply: null, upTo: _) => [
          ModelCallRefused(hash: entry.id, proposed: proposed),
        ],
      };
    }
    if (entry.kind == _summaryAskedKind) {
      final belongs =
          entry.previous != null && onChain.contains(entry.previous);
      if (!belongs) return const [];
      onChain.add(entry.id);
      final asked = HistorySummaryAsked.decode(entry.body);
      if (asked == null) return const [];
      summariesAsked[asked.step] = asked.upTo;
      return [SummaryAsked(hash: entry.id, asked: asked)];
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
/// it answers, the model's reply, or null when the model did not run, and
/// the last event the call summarizes, null for an answer. Null for an
/// outcome of anything else. An outcome whose result does not decode ends
/// its call too, with no reply.
({ObjectId proposed, ModelReply? reply, ObjectId? upTo})? _modelCallEndIn(
  List<int> body,
  Map<EntryId, ObjectId?> modelCalls,
) {
  final outcome = readOutcomeOfProposedAction(_text(body));
  if (outcome == null || !modelCalls.containsKey(outcome.proposed)) {
    return null;
  }
  final proposed = ObjectId.parse(outcome.proposed.hex)!;
  final upTo = modelCalls[outcome.proposed];
  try {
    return (
      proposed: proposed,
      reply: switch (decodeOutcome(outcome.result, decodeModelReply)) {
        Ran(:final output) => output,
        NothingRan() || StoppedPartway() => null,
      },
      upTo: upTo,
    );
  } on FormatException {
    return (proposed: proposed, reply: null, upTo: upTo);
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
/// and reply. A [SummaryByAgent] is a user turn standing in for what it
/// covers, so pass a [requestWindow], never a whole history once a summary
/// exists. A reply goes where the call it answers was proposed, not
/// where its outcome arrived, so a message admitted while the model was
/// answering comes after that answer, as the model saw it.
///
/// A reply that calls tools is followed by one answer per call, in the
/// order it made them: its fetch's result, why it can't run, or that it was
/// never run. [tools] are the trajectory's, by name. A fetch's result that
/// a model call was already sent in an earlier turn (before the latest
/// message that starts one) goes as [shortenedEarlierResult]: the model has
/// answered with it. One that ended after a new message arrived, before
/// any model call saw it, goes whole.
List<ModelTurn> trajectoryInput(
  List<TrajectoryEvent> history, {
  required Map<ToolName, OneActionTool> tools,
}) {
  final replies = {
    for (final event in history)
      if (event case SaidByAgent(:final proposed, :final reply))
        proposed: reply,
  };
  final sentInAnEarlierTurn = _fetchesSentInAnEarlierTurn(history);
  ToolResult answer(int step, int index, ToolCall call) {
    final result = _answerTo(history, step, index, call, tools);
    final ended = switch (_fetchAt(history, _callPlace(step, index))) {
      final fetch? => _fetchEnd(history, fetch),
      null => null,
    };
    return ended != null && sentInAnEarlierTurn.contains(ended.hash)
        ? shortenedEarlierResult(result, tool: call.name, step: step)
        : result;
  }

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
                      result: answer(place.step, i, call),
                    ),
                ],
            },
        ],
        SummaryByAgent(:final reply) => [
          UserSaid('$_summaryLead${reply.text}'),
        ],
        ActionProposed() ||
        SaidByAgent() ||
        ModelCallRefused() ||
        FetchEnded() ||
        SummaryAsked() ||
        TrajectoryStarted() ||
        TrajectoryRulesUnreadable() => const [],
      },
  ];
}

/// Leads a summary's text, so the model reads it as its own earlier notes
/// rather than something the user just said.
const _summaryLead = 'Your summary of this conversation before this point:\n\n';

/// The fetch ends in [history] that a model call came after, before the
/// latest message that starts a turn: each was sent to the model whole.
Set<ObjectId> _fetchesSentInAnEarlierTurn(List<TrajectoryEvent> history) {
  final currentTurnFrom = history.lastIndexWhere(
    (e) => e is SaidByUser && e.startsTurn,
  );
  final ended = <ObjectId>{};
  final sent = <ObjectId>{};
  for (final event in history.take(currentTurnFrom < 0 ? 0 : currentTurnFrom)) {
    switch (event) {
      case FetchEnded(:final hash):
        ended.add(hash);
      case ActionProposed(asksTheModel: true):
        sent.addAll(ended);
      case SaidByUser() ||
          SaidByAgent() ||
          ModelCallRefused() ||
          SummaryByAgent() ||
          SummaryAsked() ||
          ActionProposed() ||
          TrajectoryStarted() ||
          TrajectoryRulesUnreadable():
        continue;
    }
  }
  return sent;
}

/// A result over this many tokens, from an earlier turn, goes as a stub.
/// The stub itself is about 40.
const shortenResultsOverTokens = 100;

/// [result], a tool's answer from an earlier turn, as the model is sent it:
/// whole when it is under [shortenResultsOverTokens] or a refusal, which
/// is short already; otherwise a stub naming [tool], [step] and its size,
/// in the same variant so the model still knows whether it ran. Tokens are
/// estimated as four characters each.
ToolResult shortenedEarlierResult(
  ToolResult result, {
  required CalledToolName tool,
  required int step,
}) {
  String stub(String text) =>
      '[Not repeated: in an earlier turn, ${tool.asSent} at step $step '
      'returned about ${_estimatedTokens(text)} tokens. Call ${tool.asSent} '
      'again if you need it.]';
  return switch (result) {
    ToolRan(:final text)
        when _estimatedTokens(text) > shortenResultsOverTokens =>
      ToolRan(stub(text)),
    ToolFailed(:final text)
        when _estimatedTokens(text) > shortenResultsOverTokens =>
      ToolFailed(stub(text)),
    ToolRan() || ToolFailed() || ToolRefused() => result,
  };
}

int _estimatedTokens(String text) => (text.length / 4).ceil();

/// What the model hears about [call], the [index]th call of [step]'s reply,
/// read against [tools]: why it can't run, its fetch's result once ended,
/// or [notRun].
ToolResult _answerTo(
  List<TrajectoryEvent> history,
  int step,
  int index,
  ToolCall call,
  Map<ToolName, OneActionTool> tools,
) => switch (toolCalled(call, tools)) {
  CallCannotRun(:final result) => result,
  CallRuns() => switch (_fetchAt(history, _callPlace(step, index))) {
    null => notRun,
    final fetch => _fetchEnd(history, fetch)?.result ?? notRun,
  },
};

/// The calls [reply] makes, or null when it makes none.
List<ToolCall>? _callsIn(ModelReply reply) => switch (reply) {
  ProposedToolCalls(:final calls) => calls,
  FinishedReply() || CutOffReply() => null,
};

/// Where the [index]th call of [step]'s reply proposes its tool's one
/// action: each call is its own intent, and a one-action tool's action is 0.
ProposedForAnIntent _callPlace(int step, int index) =>
    ProposedForAnIntent.at(step, index, 0);

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
          SummaryByAgent() ||
          SummaryAsked() ||
          ActionProposed():
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
          SummaryByAgent() ||
          SummaryAsked() ||
          ActionProposed() ||
          TrajectoryStarted() ||
          TrajectoryRulesUnreadable():
        continue;
    }
  }
  return null;
}

/// The latest entry this loop wrote on its own chain that [history] holds:
/// a proposal or a summary marker. A restarted loop's chain resumes after
/// it.
ObjectId? lastOwnEntry(List<TrajectoryEvent> history) => [
  for (final event in history)
    if (event is ActionProposed || event is SummaryAsked) event.hash,
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
        program: ProposedProgram.askTheModel ||
            ProposedProgram.askTheModelForASummary ||
            ProposedProgram.fetchFromWeb,
      ))
        event,
  ];
  final ended = {
    for (final event in history)
      if (event
          case SaidByAgent(:final proposed) ||
              SummaryByAgent(:final proposed) ||
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
///
/// With a [compactMargin], a summary is owed too: first one whose
/// [SummaryAsked] marker was written but whose call never went out, at the
/// marker's step; otherwise, when nothing else is owed, one up to a final
/// reply that left less than [compactMargin] tokens of the context window
/// ([replyOverTheLine]). Never in the middle of a tool loop, so a summary's
/// boundary never parts a reply's tool calls from their results.
StepOwed? stepOwed(
  List<TrajectoryEvent> history, {
  required Map<ToolName, OneActionTool> tools,
  required PlaceInTrajectory? latestOwn,
  int? compactMargin,
}) {
  if (!actionsSettled(history, latestOwn: latestOwn)) return null;
  if (compactMargin == null) return _conversationStepOwed(history, tools);
  if (_summaryNeverProposed(history) case final asked?) {
    return SummaryOwed(upTo: asked.upTo, step: asked.step);
  }
  if (_conversationStepOwed(history, tools) case final owed?) return owed;
  return switch (replyOverTheLine(history, compactMargin)) {
    final over? => SummaryOwed(upTo: over.hash, step: null),
    null => null,
  };
}

/// The latest [HistorySummaryAsked] marker in [history] whose step has no
/// model call proposed: the loop wrote it, then stopped before proposing.
HistorySummaryAsked? _summaryNeverProposed(List<TrajectoryEvent> history) {
  final asked = history.whereType<SummaryAsked>().lastOrNull?.asked;
  if (asked == null) return null;
  final place = ProposedForTheModelCall.at(asked.step);
  final proposed = history.any((e) => e is ActionProposed && e.place == place);
  return proposed ? null : asked;
}

/// What [stepOwed] says is owed to the conversation itself, once settled.
StepOwed? _conversationStepOwed(
  List<TrajectoryEvent> history,
  Map<ToolName, OneActionTool> tools,
) {
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
        final place = _callPlace(call.place.step, i);
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
      (e) => e.place is ProposedForTheReply && e.place.step == call.place.step,
    );
    return replied ? null : ModelCallsSpent(step: call.place.step);
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

/// Ask the model, at the loop's next step: what it last said or was told,
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
/// [step]'s reply still calls tools: say so, as [step]'s reply, and ask
/// nothing more until another message arrives.
final class ModelCallsSpent extends StepOwed {
  const ModelCallsSpent({required this.step});

  final int step;
}

/// Ask the model to summarize the conversation up to and including the
/// event [upTo], as a step of its own: at [step] when its marker is
/// already written, otherwise at the loop's next step, marking it first.
final class SummaryOwed extends StepOwed {
  const SummaryOwed({required this.upTo, required this.step});

  final ObjectId upTo;
  final int? step;
}

/// The latest place this loop has proposed at in [history], or null for
/// none: a restarted loop's next step goes after it, never reusing a place.
PlaceInTrajectory? lastPlace(List<TrajectoryEvent> history) =>
    [
      for (final event in history)
        if (event case ActionProposed(:final place)) place,
    ].fold(
      null,
      (latest, place) =>
          latest == null || place.compareTo(latest) > 0 ? place : latest,
    );
