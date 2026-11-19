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
import 'dart:convert' show jsonDecode, utf8;

import 'package:is_airlock_api/is_airlock_api.dart'
    show
        ActionProposedByAgentLoop,
        AskTheModel,
        outcomeOfProposedActionKind,
        readOutcomeOfProposedAction;
import 'package:is_docking_station/is_docking_station.dart'
    show
        AddressInExternalSystem,
        DecisionEntryKind,
        EventAdmittedToMission,
        MessageSaid,
        decodeDecision;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart'
    show Entry, LogbookReader, ObjectId;
import 'package:is_effects/is_effects.dart'
    show Ran, Refused, decodeModelReply, decodeOutcome;
import 'package:is_shapes/is_shapes.dart' show ActorId, EntryId;

import 'model_request_render.dart' show renderRequestBody;
import 'turn_envelope.dart';

/// One event in a trajectory's history, in the order it actually happened:
/// [SaidByUser] (an admitted message), [SaidByAgent] (the model's reply to
/// a call the loop proposed) or [TurnOnChain] (an entry the loop itself
/// wrote).
sealed class TrajectoryEvent {
  const TrajectoryEvent({required this.hash});

  /// The logbook entry this event was read from: what a
  /// [ModelRequest.builtFrom] names for it.
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
    required this.rawEvent,
  });

  final ActorId author;
  final String text;
  final bool startsTurn;

  /// Where this was said, such as `teams:19:abc@thread.v2`: a reply to this
  /// turn goes back here.
  final AddressInExternalSystem address;

  /// The relay's own `event` entry this admission decided (its `event`
  /// field): loop_launcher delivers it in this same feed, immediately
  /// before the admission that names it. The feed answers only
  /// `subscribe`, never `get`, so there is no other way to reach it. Null
  /// only if it somehow did not arrive first, which the
  /// feed's own contract says cannot happen. Pass its `id` and `body` to
  /// docking_station's `RelayedEvent.read` for whatever a module needs that
  /// an admission's reading doesn't carry — for Teams, the activity's
  /// `serviceUrl`, which a reply needs and which has no fixed value across
  /// tenants.
  final Entry? rawEvent;
}

/// The model's reply to a call this loop proposed, read from the airlock's
/// outcome entry for it: [hash] is that outcome entry, which is what the
/// model's later requests were built from.
final class SaidByAgent extends TrajectoryEvent {
  const SaidByAgent({required super.hash, required this.text});

  final String text;
}

/// The loop's own record that it compacted its history: [upTo] and every
/// event before it are covered by the summary the model gave in [summary],
/// that summary call's outcome entry. Written as a turn on the loop's own
/// chain, so a loop started later finds the same boundary in the record.
final class HistorySummarized {
  const HistorySummarized({required this.summary, required this.upTo});

  static const shapeName = 'HistorySummarized';

  final ObjectId summary;
  final ObjectId upTo;

  Map<String, Object?> toJson() => {
    'shape': shapeName,
    'summary': summary.hex,
    'upTo': upTo.hex,
  };

  /// [node] as one, as [toJson] wrote it; null for any other node.
  static HistorySummarized? fromJson(Map<String, Object?> node) =>
      switch (node) {
        {
          'shape': shapeName,
          'summary': final String summary,
          'upTo': final String upTo,
        } =>
          switch ((ObjectId.parse(summary), ObjectId.parse(upTo))) {
            (final summary?, final upTo?) => HistorySummarized(
              summary: summary,
              upTo: upTo,
            ),
            _ => null,
          },
        _ => null,
      };
}

/// A [HistorySummarized] turn, read back off the loop's own chain.
final class HistorySummarizedOnChain extends TrajectoryEvent {
  const HistorySummarizedOnChain({required super.hash, required this.marker});

  final HistorySummarized marker;
}

/// The summary that stands in for everything before a [HistorySummarized]
/// boundary: built by [requestWindow], never read off the feed. [hash] is
/// the summary call's outcome entry.
final class SummaryOfEarlierHistory extends TrajectoryEvent {
  const SummaryOfEarlierHistory({required super.hash, required this.text});

  final String text;
}

/// An entry the loop itself wrote on its own turn chain.
final class TurnOnChain extends TrajectoryEvent {
  const TurnOnChain({required super.hash, required this.turn});

  final TurnEnvelope turn;
}

final _eventKind = Kind.parse('event')!;
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
/// The relay's raw `event` entries arrive too, each immediately before the
/// admission that names it (loop_launcher's contract): held here, by id,
/// until that admission turns up to claim it, never emitted as their own
/// [TrajectoryEvent] since nothing here knows what to render of one — that
/// is a module's job, done with [SaidByUser.rawEvent] once it is read.
///
/// The loop's own proposals arrive too, and the airlock's outcome of each:
/// a proposal that asks the model is remembered by id, and an outcome
/// naming one, if the model ran, becomes a [SaidByAgent]. Every other
/// proposal and outcome (a refused call, a web request) is skipped.
///
/// Built with [Stream.expand] rather than `async*`, for the same reason as
/// [followTrajectory]: `expand` passes a cancel straight through to
/// [LogbookReader.subscribe], which an `async*` wrapper would not.
Stream<TrajectoryEvent> followTrajectoryHistory(
  LogbookReader reader, {
  required Kind turnKind,
  required ObjectId chainRoot,
}) {
  final onChain = <ObjectId>{chainRoot};
  final rawEvents = <ObjectId, Entry>{};
  final modelCalls = <EntryId>{};
  final kinds = {
    turnKind,
    DecisionEntryKind.eventAdmittedToMission,
    _eventKind,
    _proposedKind,
    _outcomeKind,
  };
  return reader.subscribe(kinds: kinds).expand((item) {
    if (item is! Entry) return const [];
    if (item.kind == _proposedKind) {
      if (ActionProposedByAgentLoop.read(_jsonOrNull(item.body))
          case ActionProposedByAgentLoop(program: AskTheModel())) {
        modelCalls.add(EntryId.parse(item.id.hex)!);
      }
      return const [];
    }
    if (item.kind == _outcomeKind) {
      final reply = _modelReplyIn(item.body, modelCalls);
      return reply == null
          ? const []
          : [SaidByAgent(hash: item.id, text: reply)];
    }
    if (item.kind == turnKind) {
      final belongs = item.previous != null && onChain.contains(item.previous);
      if (!belongs) return const [];
      onChain.add(item.id);
      final turn = TurnEnvelope.decode(item.body);
      final marker = HistorySummarized.fromJson(turn.node);
      return [
        marker == null
            ? TurnOnChain(hash: item.id, turn: turn)
            : HistorySummarizedOnChain(hash: item.id, marker: marker),
      ];
    }
    if (item.kind == _eventKind) {
      rawEvents[item.id] = item;
      return const [];
    }
    final decision = decodeDecision(item.kind, item.body);
    if (decision case EventAdmittedToMission(
      :final event,
      reading: MessageSaid(:final node, :final addressInExternalSystem),
      :final startsTurn,
    )) {
      return [
        SaidByUser(
          hash: item.id,
          author: node.author,
          text: node.text,
          startsTurn: startsTurn ?? false,
          address: addressInExternalSystem,
          rawEvent: rawEvents.remove(event),
        ),
      ];
    }
    return const [];
  });
}

/// The model's reply text in [body], an outcome entry's, when it answers
/// one of [modelCalls] and the model ran; null otherwise.
String? _modelReplyIn(List<int> body, Set<EntryId> modelCalls) {
  final outcome = readOutcomeOfProposedAction(_jsonOrNull(body));
  if (outcome == null || !modelCalls.contains(outcome.proposed)) return null;
  try {
    return switch (decodeOutcome(outcome.result, decodeModelReply)) {
      Ran(:final output) => output.text,
      Refused() => null,
    };
  } on FormatException {
    return null;
  }
}

Object? _jsonOrNull(List<int> body) {
  try {
    return jsonDecode(utf8.decode(body));
  } on FormatException {
    return null;
  }
}

/// [history], oldest first, as one plain-text body: one line per event.
/// [TurnOnChain] renders through [renderRequestBody]'s own node-shape
/// cases; since ReplyText turns are dead and no `UserSaid` ever arrives
/// this way any more (it arrives as [SaidByUser] instead), nothing
/// currently reaches this case — kept for whatever the loop's own chain
/// ends up carrying. A [HistorySummarizedOnChain] renders as nothing: it
/// marks a boundary, and says nothing itself. Throws [FormatException] for
/// a [TurnOnChain] whose node shape it doesn't know how to render.
String renderTrajectoryHistory(List<TrajectoryEvent> history) => [
  for (final event in history)
    ?switch (event) {
      SaidByUser(:final text) => 'User: $text',
      SaidByAgent(:final text) => 'Agent: $text',
      SummaryOfEarlierHistory(:final text) =>
        'Summary of the conversation before this point: $text',
      TurnOnChain(:final turn) => renderRequestBody([turn]),
      HistorySummarizedOnChain() => null,
    },
].join('\n');

/// What the model is shown of [history]: everything, until the loop has
/// summarized it; after that, the latest summary in place of every event
/// it covers, then the events after its boundary. The summary call's own
/// reply and every boundary marker are left out, since neither is part of
/// the conversation. If the latest boundary names a summary or an event
/// [history] does not hold, the whole of [history] is shown rather than a
/// window that silently drops what it cannot place.
List<TrajectoryEvent> requestWindow(List<TrajectoryEvent> history) {
  final markers = history.whereType<HistorySummarizedOnChain>();
  final whole = [
    for (final event in history)
      if (event is! HistorySummarizedOnChain) event,
  ];
  if (markers.isEmpty) return whole;
  final marker = markers.last.marker;
  final summary = history
      .whereType<SaidByAgent>()
      .where((event) => event.hash == marker.summary)
      .firstOrNull;
  final upToAt = history.indexWhere((event) => event.hash == marker.upTo);
  if (summary == null || upToAt < 0) return whole;
  return [
    SummaryOfEarlierHistory(hash: summary.hash, text: summary.text),
    for (final event in history.skip(upToAt + 1))
      if (event is! HistorySummarizedOnChain && event.hash != summary.hash)
        event,
  ];
}
