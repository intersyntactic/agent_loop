/// The one seam every witnessed arrival this loop acts on goes through —
/// a live one, from `JournalReader.follow`, and one
/// `rebuildChatJourneyPaths` names unhandled — so both call the same
/// parse, and both dedupe against the same record.
library;

import 'dart:typed_data';

import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_shapes/is_shapes.dart' show TurnId;
import 'package:is_teams_module/is_teams_module.dart';

import 'chat_journey_paths.dart';
import 'seen_teams_messages.dart';
import 'witnessed_arrival.dart';

/// Turns a witnessed arrival's bytes into a [TeamsEvent]:
/// `is_teams_module`'s `teamsWitnessedEvent`, the gate's own parse
/// without its signature check, which a witnessed body's bytes alone
/// can't satisfy (no headers survive witnessing, only
/// `{at, source, bytes}`).
typedef ParseTeamsActivity = TeamsEvent? Function(List<int> activityBytes);

/// Ingests one witnessed arrival at the journal entry [arrival], whose
/// body is [body]: decodes it as a [WitnessedArrival], and, when its
/// source is `teams` and [parse] reads a [TeamsMessage] from its bytes
/// that [seen] hasn't already handled, routes it into [paths] through
/// `ingestIntoChat` and adds it to [seen]. Null when the source isn't
/// `teams`, [parse] finds nothing to ingest, or this message is already
/// in [seen] — the same activity witnessed twice (a relay restart's
/// retry, or a retry after a partial witness) must not become a second
/// turn.
Future<TurnId?> ingestWitnessedArrival(
  EntryHash arrival,
  Uint8List body, {
  required ParseTeamsActivity parse,
  required ChatJourneyPaths paths,
  required SeenTeamsMessages seen,
}) async {
  final witnessed = WitnessedArrival.decode(body);
  if (witnessed.source.toString() != 'teams') return null;
  final event = parse(witnessed.bytes);
  if (event is! TeamsMessage) return null;
  final chat = paths.forChat(event.conversation);
  final said = chat.translator.said(event);
  if (said == null || seen.contains(said.said.source)) return null;
  final turn = await ingestIntoChat(event, paths: paths, arrival: arrival);
  if (turn != null) seen.add(said.said.source);
  return turn;
}
