/// Each trajectory's own agent loop: it holds only the model
/// sign-ins its rules allow and calls the model itself, and it writes the
/// conversation's turns straight to the logbook.
///
/// [TrajectoryChain] is one trajectory's sequence of turns, written to the
/// logbook (the live record service, `is_logbook`), each in a
/// [TurnEnvelope] naming its [TurnProvenance] — a turn's own id is its
/// logbook entry hash, read back as that same id, not a second name derived
/// from it. [findTrajectoryRoot] and [followTrajectory] are its read side.
///
/// [LogbookWriter] speaks `is_logbook_client`'s write socket: both
/// [TrajectoryChain] and [ReplyChunkChain] send their entries through it,
/// each to its own chain. A reply's chunk chain is separate from its
/// trajectory's: a chunk isn't a turn and gets no turn id, only its own
/// entry hash — each role keeps its own chain rather than sharing one. Its
/// root entry names the trajectory chain's tip it started from, so an
/// in-progress stream can be tied to a trajectory before it closes.
///
/// [recordModelRequestOnTrajectory] is the write side of a model call as an
/// action: it records the exact rendered body as pieces, then a request
/// naming them, before the airlock ever sees it, so the airlock's own
/// record of what the step sent can point at it by hash rather than
/// duplicate it. [renderRequestBody] flattens turns read back off the
/// chain into the one plain-text body `claude -p` takes.
library;

export 'src/logbook_writer.dart';
export 'src/model_request_render.dart';
export 'src/reply_chunk_chain.dart';
export 'src/trajectory_chain.dart';
export 'src/trajectory_crux.dart';
export 'src/trajectory_history.dart';
export 'src/trajectory_results.dart';
export 'src/trajectory_model_request.dart';
export 'src/turn_envelope.dart';
