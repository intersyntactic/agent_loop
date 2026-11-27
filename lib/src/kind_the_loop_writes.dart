/// Every kind of logbook entry the loop writes on its trajectory's chain.
/// The logbook's sender table must grant each of these to the loop's user,
/// or the write is refused and the loop exits.
library;

import 'package:is_airlock_api/is_airlock_api.dart'
    show ActionProposedByAgentLoop, ModelRequestFromPieces, ModelRequestPiece;
import 'package:is_logbook_client/is_logbook_client.dart' show Kind;

import 'history_compaction.dart' show HistorySummaryAsked;

/// A kind of entry [TrajectoryChain.appendEntry] can write. No other kind
/// can reach the logbook from the loop.
enum KindTheLoopWrites {
  modelRequestPiece(ModelRequestPiece.kind),
  modelRequest(ModelRequestFromPieces.kind),
  actionProposed(ActionProposedByAgentLoop.kind),
  historySummaryAsked(HistorySummaryAsked.kind);

  const KindTheLoopWrites(this.wireName);

  /// The kind as the logbook and its sender table spell it.
  final String wireName;

  Kind get kind => Kind.parse(wireName)!;
}
