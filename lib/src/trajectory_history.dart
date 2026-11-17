/// A trajectory's history as the loop actually sees it, live: the user's
/// own messages arrive as `event-admitted-to-mission` entries (the docking
/// station's own kind), never as turns on the loop's chain — confirmed
/// directly with docking-station-cc, 2026-11-18, not guessed. Only the
/// loop's own turn-chain entries (confirmed to still carry `UserSaid`'s
/// data, since [MessageSaid.node] IS one) are read by [followTrajectory];
/// this reads both, merged in logbook order.
///
/// What a prior agent reply looked like is not here yet: ReplyText turns
/// are dead (RULINGS; Nick, 2026-11-18 00:32 — a loop must not write one),
/// so a prior reply has to be read from the `returned` entry of whichever
/// proposal produced it, which this loop does not yet track across
/// restarts.
library;

import 'dart:async';

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
import 'package:is_shapes/is_shapes.dart' show ActorId;

import 'model_request_render.dart' show renderRequestBody;
import 'turn_envelope.dart';

/// One event in a trajectory's history, in the order it actually happened:
/// [SaidByUser] (an admitted message) or [TurnOnChain] (an entry the loop
/// itself wrote).
sealed class TrajectoryEvent {
  const TrajectoryEvent();
}

/// A message the docking station admitted, read from its
/// `event-admitted-to-mission` entry, never from a turn: [startsTurn] is
/// whether the turn rule said the agent should answer it, false for
/// something admitted as context only.
final class SaidByUser extends TrajectoryEvent {
  const SaidByUser({
    required this.hash,
    required this.author,
    required this.text,
    required this.startsTurn,
    required this.address,
    required this.rawEventEntry,
  });

  /// The `event-admitted-to-mission` entry's own hash: what a
  /// [ModelRequest.builtFrom] names for this event, since it is where this
  /// text actually came from, not a turn.
  final ObjectId hash;
  final ActorId author;
  final String text;
  final bool startsTurn;

  /// Where this was said, such as `teams:19:abc@thread.v2`: a reply to this
  /// turn goes back here.
  final AddressInExternalSystem address;

  /// The relay's own `event` entry this admission decided (its `event`
  /// field, confirmed against docking_station's own decision.dart and
  /// decision_wire.dart by teams-module-e2): read back with
  /// `LogbookReader.get` and `RelayedEvent.read`, its raw bytes hold
  /// whatever a module needs that an admission's reading doesn't carry —
  /// for Teams, the activity's `serviceUrl`, which a reply needs and which
  /// has no fixed value across tenants.
  final ObjectId rawEventEntry;
}

/// An entry the loop itself wrote on its own turn chain.
final class TurnOnChain extends TrajectoryEvent {
  const TurnOnChain(this.hash, this.turn);

  final ObjectId hash;
  final TurnEnvelope turn;
}

/// Every event on [chainRoot]'s trajectory, live, in logbook order: the
/// loop's own turns (by the same chain-membership rule [followTrajectory]
/// uses) and every `MessageSaid` the docking station admitted to this
/// trajectory — trusting the feed's own scoping for the latter, since an
/// admission is never chained onto the loop's turns at all. An admission
/// whose reading is not something said (a join, a change) is skipped: this
/// loop has nothing to render for it yet.
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
  final kinds = {turnKind, DecisionEntryKind.eventAdmittedToMission};
  return reader.subscribe(kinds: kinds).expand((item) {
    if (item is! Entry) return const [];
    if (item.kind == turnKind) {
      final belongs = item.previous != null && onChain.contains(item.previous);
      if (!belongs) return const [];
      onChain.add(item.id);
      return [TurnOnChain(item.id, TurnEnvelope.decode(item.body))];
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
          rawEventEntry: event,
        ),
      ];
    }
    return const [];
  });
}

/// [history], oldest first, as one plain-text body: one line per event.
/// [TurnOnChain] renders through [renderRequestBody]'s own node-shape
/// cases; since ReplyText turns are dead and no `UserSaid` ever arrives
/// this way any more (it arrives as [SaidByUser] instead), nothing may
/// actually land here tonight — kept for whatever the loop's own chain
/// does carry once that's decided. Throws [FormatException] for a
/// [TurnOnChain] whose node shape it doesn't know how to render.
String renderTrajectoryHistory(List<TrajectoryEvent> history) => history
    .map(
      (event) => switch (event) {
        SaidByUser(:final text) => 'User: $text',
        TurnOnChain(:final turn) => renderRequestBody([turn]),
      },
    )
    .join('\n');
