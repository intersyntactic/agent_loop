/// Keeping a trajectory's request inside the model's context window: once
/// a final reply says the context left has fallen below a margin, the loop
/// asks the model to summarize, and later requests send that summary in
/// place of everything it covers.
///
/// The summary call is a turn of its own: one model call, at
/// [ProposedForTheModelCall], with no intents and no reply. It sends the
/// same system prompt, tools and input as the answer that crossed the line,
/// plus that answer's reply and one final user item asking for the
/// summary, so the provider's cache of that prefix carries over. Its
/// outcome entry is the summary; nothing else holds it.
library;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_airlock_api/is_airlock_api.dart'
    show ProposedForTheModelCall;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show FinishedReply, ModelTurn, ToolName, UserSaid;
import 'package:is_tools_api/is_tools_api.dart' show OneActionTool;

import 'trajectory_history.dart';

/// The loop's own record, written on its chain just before it proposes the
/// summary call: [turn]'s model call summarizes [upTo] and every event
/// before it. Written first, so a loop replaying the logbook tells that
/// call from an answer whether or not it ever came back, and proposes it
/// at the same turn if it never went out.
final class HistorySummaryAsked {
  const HistorySummaryAsked({required this.turn, required this.upTo});

  static const shapeName = 'HistorySummaryAsked';

  /// Counted from 0, as [ProposedForTheModelCall.turn] is.
  final int turn;
  final ObjectId upTo;

  Map<String, Object?> toJson() => {
    'shape': shapeName,
    'turn': turn,
    'upTo': upTo.hex,
  };

  /// [node] as one, as [toJson] wrote it; null for any other node.
  static HistorySummaryAsked? fromJson(Map<String, Object?> node) {
    final json = JsonObject.parse(node);
    // wire-ok: a node's shape name, read once here
    if (json == null || json.raw('shape') != shapeName) return null;
    final turn = json.raw('turn');
    final upTo = switch (json.raw('upTo')) {
      final String hex => ObjectId.parse(hex),
      _ => null,
    };
    return turn is int && turn >= 0 && upTo != null
        ? HistorySummaryAsked(turn: turn, upTo: upTo)
        : null;
  }
}

/// The final user item of a summary call.
const summaryInstruction =
    'Summarize this conversation so far, so that you can carry on from your '
    'summary alone: who is involved, what was asked and decided, what is '
    'still open, and any names, numbers or wording that must be kept '
    'exactly. Reply with the summary only.';

/// What the model is shown of [history]: everything, until a summary has
/// come back; after that, the latest finished summary in place of every
/// event it covers, then the events after its boundary. Summary calls' own
/// markers, proposals and replies are never part of the conversation (a
/// refused one shows nothing anyway), so
/// they are left out either way. A summary whose boundary [history] does
/// not hold is passed over rather than trusted to drop what it cannot
/// place.
List<TrajectoryEvent> requestWindow(List<TrajectoryEvent> history) {
  final conversation = [
    for (final event in history)
      if (!_isSummaryCall(event)) event,
  ];
  for (final summary in history.reversed.whereType<SummaryByAgent>()) {
    if (summary.reply is! FinishedReply) continue;
    final upToAt = conversation.indexWhere((e) => e.hash == summary.upTo);
    if (upToAt < 0) continue;
    return [summary, ...conversation.skip(upToAt + 1)];
  }
  return conversation;
}

/// Whether [event] belongs to a summary call rather than the conversation.
bool _isSummaryCall(TrajectoryEvent event) => switch (event) {
  SummaryAsked() || SummaryByAgent() => true,
  ActionProposed(program: ProposedProgram.askTheModelForASummary) => true,
  SaidByUser() ||
  SaidByAgent() ||
  ModelCallRefused() ||
  FetchEnded() ||
  ActionProposed() ||
  TrajectoryStarted() ||
  TrajectoryRulesUnreadable() ||
  TurnOnChain() => false,
};

/// The latest reply in [history]'s [requestWindow] when it left less than
/// [margin] tokens of the model's context window and no summary has been
/// asked for up to it yet: the next request would carry its context, its
/// own output and whatever is said next. Null when there is room, or when
/// the driver did not report the counts to tell, which it does only on a
/// reply that calls no tools.
SaidByAgent? replyOverTheLine(List<TrajectoryEvent> history, int margin) {
  final latest = requestWindow(history).whereType<SaidByAgent>().lastOrNull;
  if (latest == null) return null;
  final usage = latest.reply.usage;
  final window = usage?.contextWindow;
  if (usage == null || window == null) return null;
  if (window - usage.context - usage.output >= margin) return null;
  final asked = history.any(
    (e) => e is SummaryAsked && e.asked.upTo == latest.hash,
  );
  return asked ? null : latest;
}

/// The summary call's input: [history]'s window up to and including
/// [upTo], as the answer that produced [upTo] sent it plus its reply, then
/// [summaryInstruction]. Null when [upTo] is not in the window.
({List<TrajectoryEvent> covered, List<ModelTurn> input})? summaryRequest(
  List<TrajectoryEvent> history,
  ObjectId upTo, {
  required Map<ToolName, OneActionTool> tools,
}) {
  final window = requestWindow(history);
  final upToAt = window.indexWhere((e) => e.hash == upTo);
  if (upToAt < 0) return null;
  final covered = window.sublist(0, upToAt + 1);
  return (
    covered: covered,
    input: [
      ...trajectoryInput(covered, tools: tools),
      const UserSaid(summaryInstruction),
    ],
  );
}
