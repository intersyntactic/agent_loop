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
/// [JournalReader] speaks the journal's separate read socket: `tipOf`
/// asks a chain's tip, `follow` streams entries of given kinds from a
/// point then live, surfacing `caught-up` as its own [FollowItem].
///
/// [ChatJourneyPaths]/[ingestIntoChat] give each Teams chat its own
/// journey path (one chain, one [TeamsTranslator]), keyed by
/// `TeamsConversation.id`. [rebuildChatJourneyPaths] replays the record
/// through `caught-up` to recover one on restart, naming the `witnessed`
/// arrivals still unhandled when history ran out and every
/// `SourceMessageId` already handled.
///
/// [ingestWitnessedArrival] is the one seam a witnessed arrival's bytes
/// become a turn through, live or replayed: [WitnessedArrival.decode]
/// reads `is_airlock`'s `{at, source, bytes}` format, it parses with
/// `is_teams_module`'s `teamsWitnessedEvent`, and dedupes against
/// [SeenTeamsMessages] — Teams may witness the same activity twice.
///
/// Not here yet: taking a turn with a model.
library;

export 'src/chat_journey_paths.dart';
export 'src/chat_journey_paths_rebuild.dart';
export 'src/ingest_witnessed_arrival.dart';
export 'src/journal_reader.dart';
export 'src/journal_writer.dart';
export 'src/journey_path_chain.dart';
export 'src/seen_teams_messages.dart';
export 'src/teams_arrival_ingest.dart';
export 'src/turn_envelope.dart';
export 'src/witnessed_arrival.dart';
