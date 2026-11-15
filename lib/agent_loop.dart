/// Each journey path's own agent loop (RULINGS): it holds only the model
/// sign-ins its rules allow and calls the model itself, and it writes the
/// conversation's turns straight to the journal.
///
/// So far, the write side: [JournalWriter] speaks the journal service's
/// write socket; [JourneyPathChain] is one journey path's sequence of
/// turns over it, each in a [TurnEnvelope] naming its [TurnProvenance] —
/// a turn's [TurnId] is its journal entry hash, read back as a [TurnId],
/// not a second name derived from it. [ingestTeamsMessage], for an
/// arrival the airlock witnessed, runs `is_teams_module`'s
/// `TeamsTranslator` and appends what it returns.
///
/// Not here yet: a read side, taking a turn with a model.
library;

export 'src/journal_writer.dart';
export 'src/journey_path_chain.dart';
export 'src/teams_arrival_ingest.dart';
export 'src/turn_envelope.dart';
