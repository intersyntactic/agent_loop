/// Each journey path's own agent loop (RULINGS): it holds only the model
/// sign-ins its rules allow and calls the model itself, and it writes the
/// conversation's turns straight to the journal.
///
/// So far, the write side: [JournalWriter] speaks the journal service's
/// write socket; [JourneyPathChain] is one journey path's sequence of
/// turns over it, each in a [TurnEnvelope] naming its [TurnProvenance] —
/// a turn's [TurnId] is its journal entry hash, read back as a [TurnId],
/// not a second name derived from it.
///
/// [JournalReader] speaks the journal's separate read socket: `tipOf`
/// asks a chain's tip, `subscribe` streams entries of given kinds from a
/// point then live, surfacing `caught-up` as its own [SubscribedItem].
///
/// [ReplyChunkChain] is a streamed reply's own chain, separate from its
/// journey path's: a chunk isn't a turn and gets no [TurnId], only its
/// own entry hash (RULINGS: each chain "holds only that loop's turns;
/// each event and the airlock's entries have chains of their own"). Its
/// root entry names the journey path's chain tip it started from, so an
/// in-progress stream can be tied to a path before it closes.
///
/// [recordModelRequest] is the write side of a model call as an action
/// (RULINGS: "what a step sends is in the airlock's record"): it records
/// the exact rendered body as pieces, then a request naming them, before
/// the airlock ever sees it. [turnsUpTo] reads a chain's turns back with
/// the read side, and [renderRequestBody] flattens them into the one
/// plain-text body `claude -p` takes.
///
/// Not here yet: Teams arrivals, using the read side to recover state,
/// taking a turn with a model.
library;

export 'src/journal_reader.dart';
export 'src/journal_writer.dart';
export 'src/journey_path_chain.dart';
export 'src/model_request_recorder.dart';
export 'src/model_request_render.dart';
export 'src/reply_chunk_chain.dart';
export 'src/turn_envelope.dart';
