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
        PlaceInTrajectory,
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
    show CaughtUp, Entry, LogbookReader, ObjectId;
import 'package:is_effects/is_effects.dart'
    show
        CutOffReply,
        FinishedReply,
        ModelReply,
        Ran,
        Refused,
        decodeModelReply,
        decodeOutcome;
import 'package:is_shapes/is_shapes.dart' show ActorId, EntryId;

import 'model_request_input.dart'
    show ModelInputRole, ModelInputTurn, inputTurnOf;
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
/// a call the loop proposed), [ActionProposed] (a proposal this loop wrote)
/// or [TurnOnChain] (a turn the loop itself wrote).
sealed class TrajectoryEvent extends TrajectoryFeedItem {
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
/// model's later requests were built from. [reply] says whether the model
/// finished or was cut off, and what the call used when the driver could
/// tell.
final class SaidByAgent extends TrajectoryEvent {
  const SaidByAgent({required super.hash, required this.reply});

  final ModelReply reply;

  String get text => reply.text;
}

/// An action this loop proposed: [place] is the place it named;
/// [asksTheModel] is whether its program was AskTheModel. A replayed
/// history needs both: whether a message was already answered, and which
/// turn the next proposal starts.
final class ActionProposed extends TrajectoryEvent {
  const ActionProposed({
    required super.hash,
    required this.place,
    required this.asksTheModel,
  });

  final PlaceInTrajectory place;
  final bool asksTheModel;
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
        final asksTheModel = program is AskTheModel;
        if (asksTheModel) modelCalls.add(EntryId.parse(entry.id.hex)!);
        return [
          ActionProposed(
            hash: entry.id,
            place: place,
            asksTheModel: asksTheModel,
          ),
        ];
      }
      return const [];
    }
    if (entry.kind == _outcomeKind) {
      final reply = _modelReplyIn(entry.body, modelCalls);
      return reply == null
          ? const []
          : [SaidByAgent(hash: entry.id, reply: reply)];
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
    if (entry.kind == _eventKind) {
      rawEvents[entry.id] = entry;
      return const [];
    }
    final decision = decodeDecision(entry.kind, entry.body);
    if (decision case EventAdmittedToMission(
      :final event,
      reading: MessageSaid(:final node, :final addressInExternalSystem),
      :final startsTurn,
    )) {
      return [
        SaidByUser(
          hash: entry.id,
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

/// The model's reply in [body], an outcome entry's, when it answers one of
/// [modelCalls] and the model ran; null otherwise.
ModelReply? _modelReplyIn(List<int> body, Set<EntryId> modelCalls) {
  final outcome = readOutcomeOfProposedAction(_text(body));
  if (outcome == null || !modelCalls.contains(outcome.proposed)) return null;
  try {
    return switch (decodeOutcome(outcome.result, decodeModelReply)) {
      Ran(:final output) => output,
      Refused() => null,
    };
  } on FormatException {
    return null;
  }
}

/// An entry's body as the text the airlock's readers take; a body that is
/// not UTF-8 reads as text they then refuse, rather than throwing here.
String _text(List<int> body) => utf8.decode(body, allowMalformed: true);

/// [history], oldest first, as a model request's turns: one per event.
/// [TurnOnChain] goes through [inputTurnOf]'s own node-shape cases; since
/// ReplyText turns are dead and no `UserSaid` ever arrives this way any
/// more (it arrives as [SaidByUser] instead), nothing currently reaches
/// this case — kept for whatever the loop's own chain ends up carrying.
/// Throws [FormatException] for a [TurnOnChain] whose node shape it doesn't
/// know.
List<ModelInputTurn> trajectoryInput(List<TrajectoryEvent> history) => [
  for (final event in history)
    ?switch (event) {
      SaidByUser(:final text) => ModelInputTurn(ModelInputRole.user, text),
      SaidByAgent(:final reply) => ModelInputTurn(
        ModelInputRole.assistant,
        switch (reply) {
          FinishedReply(:final text) => text,
          CutOffReply(:final text) => '$text\n\n$_cutOffNote',
        },
      ),
      TurnOnChain(:final turn) => inputTurnOf(turn),
      ActionProposed() => null,
    },
];

/// Follows a cut-off reply's text in the model's own history, so it knows
/// that reply stopped short rather than reading it as finished.
const _cutOffNote = '(This reply was cut off before it finished.)';

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
      case SaidByUser() || SaidByAgent() || ActionProposed() || TurnOnChain():
        continue;
    }
  }
  return null;
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
