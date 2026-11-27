/// Each trajectory's own agent loop: it writes its model requests and
/// proposals straight to the logbook and proposes each model call through
/// it as a [ProposesAtNextPlace]; the airlock makes the call.
///
/// [TrajectoryChain] is one trajectory's sequence of the loop's own
/// entries in the logbook (the live logbook service, `is_logbook`), each of
/// a [KindTheLoopWrites]. An entry's id is its logbook entry hash.
/// [findTrajectoryRoot] and [followTrajectoryHistory] are its read side.
///
/// [LogbookWriter] speaks `is_logbook_client`'s write socket:
/// [TrajectoryChain] sends its entries through it.
///
/// [recordModelRequestOnTrajectory] is the write side of a model call as an
/// action: it records the exact rendered body as pieces, then a request
/// naming them, before the airlock ever sees it, so the airlock's own
/// logbook entry for what the step sent can point at it by hash rather than
/// duplicate it. [trajectoryInput] gives a request's turns, as
/// is_model_vocabulary's `ModelTurn`s every model driver reads, and
/// [offeredTools] the tools beside them.
library;

export 'src/history_compaction.dart';
export 'src/kind_the_loop_writes.dart';
export 'src/logbook_writer.dart';
export 'src/loop_exit.dart';
export 'src/proposes_at_next_place.dart';
export 'src/reply.dart';
export 'src/tool_action.dart';
export 'src/tool_calls.dart';
export 'src/trajectory_chain.dart';
export 'src/trajectory_history.dart';
export 'src/trajectory_model_request.dart';
export 'src/trajectory_proposal_link.dart';
export 'src/trajectory_results.dart';
