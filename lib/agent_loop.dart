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
/// asks a chain's tip, `follow` streams entries of given kinds from a
/// point then live, surfacing `caught-up` as its own [FollowItem].
///
/// [ReplyChunkChain] is a streamed reply's own chain, separate from its
/// journey path's: a chunk isn't a turn and gets no [TurnId], only its
/// own entry hash (RULINGS: each chain "holds only that loop's turns;
/// each event and the airlock's entries have chains of their own").
///
/// Not here yet: Teams arrivals, using the read side to recover state,
/// taking a turn with a model, posting through the airlock.
library;

export 'src/journal_reader.dart';
export 'src/journal_writer.dart';
export 'src/journey_path_chain.dart';
export 'src/reply_chunk_chain.dart';
export 'src/turn_envelope.dart';
