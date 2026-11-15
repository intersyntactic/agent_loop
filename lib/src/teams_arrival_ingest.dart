/// For each Teams message the airlock has witnessed, runs
/// [TeamsTranslator] and appends what it returns to the journey path's
/// chain: a [TeamsConversation] first, when the chat is new to this
/// journey path or Teams has moved it, then the [UserSaid]. [translator]
/// learns the [TurnId] each one was given, through [TeamsTranslator.joined]
/// and [TeamsTranslator.heard], the same way any module meets a journey
/// path (RULINGS; `is_conversation_shapes`' [UserSaid] doc).
library;

import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_shapes/is_shapes.dart';
import 'package:is_teams_module/is_teams_module.dart';

import 'journey_path_chain.dart';
import 'turn_envelope.dart';

/// The shape and fields of [node]: what the chain's envelope carries as
/// the node. Matches `StandInJourneyPath.encodeOther`'s own encoding for
/// [TeamsConversation] and [UserSaid], so a reader that understands one
/// understands the other.
Map<String, Object?> encodeConversationNode(Object node) => switch (node) {
  TeamsConversation(:final id, :final serviceUrl) => {
    'shape': 'TeamsConversation',
    'id': id,
    'serviceUrl': '$serviceUrl',
  },
  UserSaid(:final author, :final source, :final text) => {
    'shape': 'UserSaid',
    'author': '$author',
    'source': '$source',
    'text': text,
  },
  _ => throw ArgumentError.value(node, 'node', 'has no encoding here'),
};

/// Translates [message] with [translator] and appends what it returns to
/// [chain], each as a turn [FromArrival] the journal entry hash [arrival]
/// names. Null when [translator] found nothing to append: no author, no
/// text, or a source id it can't parse.
Future<TurnId?> ingestTeamsMessage(
  TeamsMessage message, {
  required TeamsTranslator translator,
  required JourneyPathChain chain,
  required EntryHash arrival,
}) async {
  final result = translator.said(message);
  if (result == null) return null;
  final provenance = FromArrival(arrival);
  if (result.joined case final conversation?) {
    await chain.append(encodeConversationNode(conversation), provenance);
    translator.joined(conversation);
  }
  final id = await chain.append(
    encodeConversationNode(result.said),
    provenance,
  );
  translator.heard(id, result.said);
  return id;
}
