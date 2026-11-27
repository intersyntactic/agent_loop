/// The loop's link to the logbook for its proposals: the one holder that
/// extends the trajectory. Writes each proposal as an
/// [ActionProposedByAgentLoop] entry on the trajectory's own chain, and
/// hands back the airlock's `outcomeOfProposedActionKind` entry naming it;
/// [ProposesAtNextPlace] joins the two and checks the outcome names the
/// proposal.
///
/// The airlock names a proposal by the [ObjectId] the write's own `ok`
/// answer gives — the whole recorded entry, not a hash of the proposal's
/// raw bytes alone, which carries no trace of where it landed on the
/// chain and so never matches it.
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io' show stdout;

import 'package:is_airlock_api/is_airlock_api.dart'
    show ActionProposedByAgentLoop, PlaceInTrajectory;
import 'package:is_shapes/is_shapes.dart' show EntryId;

import 'kind_the_loop_writes.dart';
import 'loop_exit.dart' show FeedEnded;
import 'proposes_at_next_place.dart';
import 'trajectory_chain.dart';

/// One `outcomeOfProposedActionKind` entry, read back: the proposal it
/// names, its own id in the logbook, and its whole body as text, built by
/// [followResults] from a live [LogbookReader] subscription.
typedef ReturnedResult = ({EntryId proposed, EntryId resultEntry, String body});

/// [chain]'s loop, as the one proposer of its trajectory's next action:
/// every [writeProposal] lands on [chain]'s own tip, and [outcomeNaming]
/// waits on [returned] for the matching result.
///
/// Listens to [returned] once, from construction, and keeps every result
/// until it is asked for: an outcome that arrives between a proposal's
/// write and the call that waits for it is never lost.
final class TrajectoryProposalLink implements ProposesActionsThroughTheLogbook {
  TrajectoryProposalLink({
    required this.chain,
    required Stream<ReturnedResult> returned,
  }) {
    _subscription = returned.listen(
      (result) {
        stdout.writeln('agent_loop: saw result for ${result.proposed.hex}');
        final waiting = _waiting.remove(result.proposed);
        if (waiting != null) {
          waiting.complete(result);
        } else {
          _arrived[result.proposed] = result;
        }
      },
      onError: _end,
      onDone: () => _end(
        const FeedEnded("the logbook's result entries"),
        StackTrace.current,
      ),
      cancelOnError: true,
    );
    // Marked handled here: [ended] hands the failure to whoever waits on it.
    _ended.future.ignore();
  }

  final TrajectoryChain chain;
  late final StreamSubscription<ReturnedResult> _subscription;
  final _ended = Completer<Never>();

  /// The failure the results ended with, once they have: every outcome
  /// still awaited, or asked for later, fails with it.
  (Object, StackTrace)? _failure;

  /// Fails once the results stop: with their error, or [FeedEnded] if
  /// they simply ended. Never completes otherwise.
  Future<Never> get ended => _ended.future;

  void _end(Object error, StackTrace trace) {
    _failure ??= (error, trace);
    for (final waiting in _waiting.values) {
      waiting.completeError(error, trace);
    }
    _waiting.clear();
    if (!_ended.isCompleted) _ended.completeError(error, trace);
  }

  final _arrived = <EntryId, ReturnedResult>{};
  final _waiting = <EntryId, Completer<ReturnedResult>>{};

  /// Each proposal's place, by its entry, until its outcome is matched.
  final _placeOf = <EntryId, PlaceInTrajectory>{};

  /// The matching result entry's own id, by the place each proposal named:
  /// a later proposal answering with the model's reply (`ReplyToEvent.reply`)
  /// has no other way to reach it. Removed once read, since each place
  /// proposes once.
  final _resultEntries = <PlaceInTrajectory, EntryId>{};

  /// [place]'s result entry, once its outcome has been handed back; null
  /// before then, or if already read.
  EntryId? resultEntryAt(PlaceInTrajectory place) =>
      _resultEntries.remove(place);

  @override
  Future<EntryId> writeProposal(String body) async {
    final written = await chain.appendEntry(
      KindTheLoopWrites.actionProposed,
      utf8.encode(body),
    );
    final id = EntryId.parse(written.hex)!;
    if (ActionProposedByAgentLoop.read(body) case ActionProposedByAgentLoop(
      :final place,
    )) {
      _placeOf[id] = place;
    }
    stdout.writeln(
      'agent_loop: proposal ${id.hex} appended, awaiting its result',
    );
    return id;
  }

  @override
  Future<String> outcomeNaming(EntryId proposed) async {
    final arrived = _arrived.remove(proposed);
    if (_failure case (final error, final trace)? when arrived == null) {
      Error.throwWithStackTrace(error, trace);
    }
    final result =
        arrived ??
        await (_waiting[proposed] ??= Completer<ReturnedResult>()).future;
    final place = _placeOf.remove(proposed);
    if (place != null) _resultEntries[place] = result.resultEntry;
    return result.body;
  }

  /// Stops listening to the results.
  Future<void> close() => _subscription.cancel();
}
