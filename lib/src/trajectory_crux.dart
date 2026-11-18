/// The loop's own crux: the one holder that extends the trajectory.
/// Proposes an action by writing an [ActionProposedByAgentLoop] entry on the
/// trajectory's own chain, then waits for the airlock's
/// `outcomeOfProposedActionKind` entry naming it, and gives back its
/// result.
///
/// The airlock names a proposal by the [ObjectId] the write's own `ok`
/// answer gives — the whole recorded entry, not a hash of the proposal's
/// raw bytes alone, which carries no trace of where it landed on the
/// chain and so never matches it.
library;

import 'dart:async';
import 'dart:convert' show jsonEncode, utf8;
import 'dart:io' show stdout;
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart'
    show ActionProposedByAgentLoop, ProposesActionsThroughTheRecord;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_shapes/is_shapes.dart' show EntryId;

import 'trajectory_chain.dart';

final _proposedKind = Kind.parse(ActionProposedByAgentLoop.kind)!;

/// One `outcomeOfProposedActionKind` entry, read back: its own id in the
/// logbook, `readOutcomeOfProposedAction`'s shape for what it holds, built
/// by whoever follows the loop's feed of them (see [followResults] in
/// bin/agent_loop.dart's package, which builds one from a live
/// [LogbookReader] subscription).
typedef ReturnedResult = ({
  EntryId proposed,
  EntryId resultEntry,
  Object? result,
});

/// [chain]'s loop, as the one proposer of its trajectory's next action:
/// every [propose] lands on [chain]'s own tip, then waits on [returned] for
/// the matching result. [returned] is every result entry the feed hands
/// this loop, decoded once, for as many proposals as this crux goes on to
/// make — not consumed by one [propose] call, since a later one still
/// needs it.
final class TrajectoryCrux implements ProposesActionsThroughTheRecord {
  TrajectoryCrux({
    required this.chain,
    required Stream<ReturnedResult> returned,
  }) : returned = returned.asBroadcastStream();

  final TrajectoryChain chain;

  /// Broadcast, not the single-subscription stream passed in: [propose]
  /// listens on every call, and a turn that posts a reply calls it twice
  /// (the model call, then the post) — a single-subscription stream can
  /// only ever be listened to once.
  final Stream<ReturnedResult> returned;

  /// The matching result entry's own id, by the place each proposal named
  /// (`propose`'s own caller never sees `Object? proposal`'s shape, so a
  /// later proposal naming a Teams reply's `WebRequest.drawnFrom` has no
  /// other way to reach it than this: `propose`'s return type is fixed by
  /// [ProposesActionsThroughTheRecord], with no room for it). Removed once
  /// read, since each place proposes once.
  final _resultEntries = <Object?, EntryId>{};

  /// [place]'s result entry, once [propose] has matched it; null before
  /// then, or if already read.
  EntryId? resultEntryAt(Object? place) => _resultEntries.remove(place);

  @override
  Future<Object?> propose(Object? proposal) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(proposal)));
    final written = await chain.appendEntry(_proposedKind, bytes);
    // The airlock names a proposal by the logbook entry's own id (the
    // kind line, the previous line, then the body) — not a hash of the
    // body alone, which carries no trace of where it landed on the
    // chain and so never matches.
    final id = EntryId.parse(written.hex)!;
    stdout.writeln(
      'agent_loop: proposal ${id.hex} appended, awaiting its result',
    );
    await for (final entry in returned) {
      stdout.writeln(
        'agent_loop: saw result for ${entry.proposed.hex}, want ${id.hex}',
      );
      if (entry.proposed != id) continue;
      if (proposal case {'place': final place}) {
        _resultEntries[place] = entry.resultEntry;
      }
      return entry.result;
    }
    throw StateError("the record's result entries ended before $id came back");
  }
}
