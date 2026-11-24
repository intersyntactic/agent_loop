/// Each trajectory's own agent loop: it writes the conversation's turns
/// straight to the logbook and proposes each model call through its crux;
/// the airlock makes the call.
///
/// [TrajectoryChain] is one trajectory's sequence of turns, written to the
/// logbook (the live logbook service, `is_logbook`), each in a
/// [TurnEnvelope] naming its [TurnProvenance] — a turn's own id is its
/// logbook entry hash, read back as that same id, not a second name derived
/// from it. [findTrajectoryRoot] and [followTrajectory] are its read side.
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

export 'src/logbook_writer.dart';
export 'src/loop_exit.dart';
export 'src/model_request_input.dart';
export 'src/reply.dart';
export 'src/tool_action.dart';
export 'src/tool_calls.dart';
export 'src/trajectory_chain.dart';
export 'src/trajectory_crux.dart';
export 'src/trajectory_history.dart';
export 'src/trajectory_results.dart';
export 'src/trajectory_model_request.dart';
export 'src/turn_envelope.dart';
