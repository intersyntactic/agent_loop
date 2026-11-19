/// Keeping a trajectory's request inside the model's context window: once
/// a reply says the context left has fallen below a margin, the loop asks
/// the model to summarize, and later requests send that summary in place of
/// everything it covers.
///
/// The summary call is the agent's own turn: the same system prompt and the
/// same input array as the answer that crossed the line, plus its reply and
/// one final user item asking for the summary, so the provider's cache of
/// that prefix carries over. Its outcome entry is the summary; nothing else
/// holds it.
library;

import 'package:is_effects/is_effects.dart' show FinishedReply;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;

import 'model_request_input.dart' show ModelInputRole, ModelInputTurn;
import 'trajectory_history.dart';

/// The loop's own record, written on its chain just before it proposes the
/// summary call: the model call at [place] summarizes [upTo] and every
/// event before it. Written first so a loop replaying the record tells that
/// call from an answer, whether or not it ever came back.
final class HistorySummaryAsked {
  const HistorySummaryAsked({required this.place, required this.upTo});

  static const shapeName = 'HistorySummaryAsked';

  final int place;
  final ObjectId upTo;

  Map<String, Object?> toJson() => {
    'shape': shapeName,
    'place': place,
    'upTo': upTo.hex,
  };

  /// [node] as one, as [toJson] wrote it; null for any other node.
  static HistorySummaryAsked? fromJson(Map<String, Object?> node) =>
      switch (node) {
        {
          'shape': shapeName,
          'place': final int place,
          'upTo': final String upTo,
        } =>
          switch (ObjectId.parse(upTo)) {
            final upTo? => HistorySummaryAsked(place: place, upTo: upTo),
            null => null,
          },
        _ => null,
      };
}

/// The final user item of a summary call.
const summaryInstruction =
    'Summarize this conversation so far, so that you can carry on from your '
    'summary alone: who is involved, what was asked and decided, what is '
    'still open, and any names, numbers or wording that must be kept '
    'exactly. Reply with the summary only.';

/// What the model is shown of [history]: everything, until a summary has
/// come back; after that, the latest finished summary in place of every
/// event it covers, then the events after its boundary. Summary calls'
/// own markers and replies are never part of the conversation, so they are
/// left out either way. A summary whose boundary [history] does not hold
/// is passed over rather than trusted to drop what it cannot place.
List<TrajectoryEvent> requestWindow(List<TrajectoryEvent> history) {
  final conversation = [
    for (final event in history)
      if (event is! SummaryAsked && event is! SummaryByAgent) event,
  ];
  for (final summary in history.reversed.whereType<SummaryByAgent>()) {
    if (summary.reply is! FinishedReply) continue;
    final upToAt = conversation.indexWhere((e) => e.hash == summary.upTo);
    if (upToAt < 0) continue;
    return [summary, ...conversation.skip(upToAt + 1)];
  }
  return conversation;
}

/// The latest reply in [history]'s [requestWindow] when it left less than
/// [margin] tokens of the model's context window: the next request would
/// carry its context, its own output and whatever is said next. Null when
/// there is room, or when the driver did not report the counts to tell.
SaidByAgent? replyOverTheLine(List<TrajectoryEvent> history, int margin) {
  final latest = requestWindow(history).whereType<SaidByAgent>().lastOrNull;
  final usage = latest?.reply.usage;
  final window = usage?.contextWindow;
  if (usage == null || window == null) return null;
  return window - usage.context - usage.output < margin ? latest : null;
}

/// The summary call's input: [history]'s window up to and including
/// [upTo], as the answer that produced [upTo] sent it plus its reply, then
/// [summaryInstruction]. Null when [upTo] is not in the window.
({List<TrajectoryEvent> covered, List<ModelInputTurn> input})? summaryRequest(
  List<TrajectoryEvent> history,
  SaidByAgent upTo,
) {
  final window = requestWindow(history);
  final upToAt = window.indexWhere((e) => e.hash == upTo.hash);
  if (upToAt < 0) return null;
  final covered = window.sublist(0, upToAt + 1);
  return (
    covered: covered,
    input: [
      ...trajectoryInput(covered),
      const ModelInputTurn(ModelInputRole.user, summaryInstruction),
    ],
  );
}
