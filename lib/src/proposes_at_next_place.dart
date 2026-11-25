/// How the loop proposes an action: as an [ActionProposedByAgentLoop]
/// logbook entry at its place in the trajectory, answered by the airlock's
/// `outcomeOfProposedActionKind` entry naming it.
library;

import 'package:is_airlock_api/is_airlock_api.dart'
    show
        PlaceInTrajectory,
        Program,
        ProposedForAnIntent,
        ProposedForTheModelCall,
        ProposedForTheReply,
        ProposesActions,
        readOutcomeOfProposedAction;
import 'package:is_effects/is_effects.dart' show Outcome;
import 'package:is_shapes/is_shapes.dart' show EntryId;

/// Writes proposals to the logbook and reads back the airlock's answers.
abstract interface class ProposesActionsThroughTheLogbook {
  /// Writes [body] as an [ActionProposedByAgentLoop] logbook entry on the
  /// loop's trajectory's chain, and gives the id the logbook gave it: the
  /// hash of the whole entry as the logbook keeps it, never of [body] alone.
  Future<EntryId> writeProposal(String body);

  /// The body of the `outcomeOfProposedActionKind` logbook entry that names
  /// [proposed], once the airlock has kept it.
  Future<String> outcomeNaming(EntryId proposed);
}

/// Proposes each action through [ProposesActionsThroughTheLogbook] at the
/// next place of one model call, one intent or one reply, counting from 0.
///
/// A place depends only on what was proposed before it here, so a loop that
/// restarts proposes the same actions at the same places.
final class ProposesAtNextPlace implements ProposesActions {
  ProposesAtNextPlace._(this._link, this._placeOf);

  /// Every action of [intent] in [turn], numbered from 0.
  factory ProposesAtNextPlace.forIntent(
    ProposesActionsThroughTheLogbook link, {
    required int turn,
    required int intent,
  }) => ProposesAtNextPlace._(
    link,
    (n) => ProposedForAnIntent.at(turn, intent, n),
  );

  /// The one action of [turn]'s model call.
  factory ProposesAtNextPlace.forTheModelCall(
    ProposesActionsThroughTheLogbook link, {
    required int turn,
  }) {
    final only = ProposedForTheModelCall.at(turn);
    return ProposesAtNextPlace._(link, (n) => n == 0 ? only : null);
  }

  /// Every action of [turn]'s reply, numbered from 0.
  factory ProposesAtNextPlace.forTheReply(
    ProposesActionsThroughTheLogbook link, {
    required int turn,
  }) => ProposesAtNextPlace._(link, (n) => ProposedForTheReply.at(turn, n));

  final ProposesActionsThroughTheLogbook _link;

  /// The place of the [n]th action proposed here, or null when it has none.
  final PlaceInTrajectory? Function(int n) _placeOf;
  int _proposed = 0;

  /// The outcome the airlock wrote to the logbook. An answer that is not
  /// one, or that names another proposal, throws a [FormatException] and
  /// ends the call: whether the action reached the world is then not known
  /// here, and the airlock's entries in the logbook say.
  @override
  Future<Outcome<O>> propose<I, O>(Program<I, O> program, I input) async {
    final place =
        _placeOf(_proposed++) ??
        (throw StateError(
          'the model call carries one action, not ${program.name} as well',
        ));
    final proposed = await _link.writeProposal(
      program.proposal(input, at: place),
    );
    return switch (readOutcomeOfProposedAction(
      await _link.outcomeNaming(proposed),
    )) {
      (proposed: final named, :final result) when named == proposed =>
        program.outcomeFromJson(result),
      (proposed: final named, result: _) => throw FormatException(
        'the outcome for $proposed names $named',
      ),
      null => throw FormatException('no outcome for $proposed'),
    };
  }
}
