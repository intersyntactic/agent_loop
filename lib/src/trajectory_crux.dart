/// The loop's own crux (RULINGS,
/// https://github.com/enspyrco/intersyntactic/pull/1168: "its agent loop,
/// the one holder that extends the trajectory" — Nick, 2026-11-18 00:30,
/// confirmed this is agent_loop's job, not a separate caller's). Proposes
/// an action by writing an [ActionProposedByAgentLoop] entry on the
/// trajectory's own chain, then waits for the airlock's
/// [resultOfActionOrWhyRefusedKind] entry naming it, and gives back its
/// result.
///
/// Confirmed against airlock-api-04 directly, not guessed from the source
/// alone: that entry's `proposed` field is `EntryId.of` the raw bytes of
/// the proposal this writes — not the [EntryHash] the write's own `ok`
/// answer gives, which depends on chain position and so differs from it.
library;

import 'dart:async';
import 'dart:convert' show jsonEncode, utf8;
import 'dart:typed_data';

import 'package:is_airlock_api/is_airlock_api.dart'
    show ActionProposedByAgentLoop, ProposesActionsThroughTheRecord;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_shapes/is_shapes.dart' show EntryId;

import 'trajectory_chain.dart';

final _proposedKind = Kind.parse(ActionProposedByAgentLoop.kind)!;

/// One [resultOfActionOrWhyRefusedKind] entry, read back: its own id in the
/// logbook, [readResultOfActionOrWhyRefused]'s shape for what it holds,
/// built by whoever follows the loop's feed of them (see [followResults] in
/// bin/agent_loop.dart's package, which builds one from a live
/// [LogbookReader] subscription).
typedef ReturnedResult = ({EntryId proposed, EntryId resultEntry, Object? result});

/// [chain]'s loop, as the one proposer of its trajectory's next action:
/// every [propose] lands on [chain]'s own tip, then waits on [returned] for
/// the matching result. [returned] is every result entry the feed hands
/// this loop, decoded once, for as many proposals as this crux goes on to
/// make — not consumed by one [propose] call, since a later one still
/// needs it.
final class TrajectoryCrux implements ProposesActionsThroughTheRecord {
  TrajectoryCrux({required this.chain, required this.returned});

  final TrajectoryChain chain;
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
    final id = EntryId.of(bytes);
    await chain.appendEntry(_proposedKind, bytes);
    await for (final entry in returned) {
      if (entry.proposed != id) continue;
      if (proposal case {'place': final place}) {
        _resultEntries[place] = entry.resultEntry;
      }
      return entry.result;
    }
    throw StateError("the record's result entries ended before $id came back");
  }
}
