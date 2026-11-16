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
/// Not here yet: Teams arrivals, using the read side to recover state,
/// taking a turn with a model.
library;

export 'src/journal_reader.dart';
export 'src/journal_writer.dart';
export 'src/journey_path_chain.dart';
export 'src/turn_envelope.dart';
