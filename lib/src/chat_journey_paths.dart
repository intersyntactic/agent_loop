/// Each Teams chat its own journey path: one [JourneyPathChain] and one
/// [TeamsTranslator] (one per path, as its own doc requires), keyed by the
/// chat's own id (`TeamsConversation.id`).
library;

import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;
import 'package:is_shapes/is_shapes.dart' show TurnId;
import 'package:is_teams_module/is_teams_module.dart';

import 'journal_writer.dart';
import 'journey_path_chain.dart';
import 'teams_arrival_ingest.dart';

/// One chat's own journey path.
final class ChatJourneyPath {
  ChatJourneyPath({required this.chain, required this.translator});

  final JourneyPathChain chain;
  final TeamsTranslator translator;
}

/// Each Teams chat's own journey path, started the first time its chat is
/// asked for.
final class ChatJourneyPaths {
  ChatJourneyPaths({required this.writer, required this.kind});

  final JournalWriter writer;
  final Kind kind;

  final Map<String, ChatJourneyPath> _byChat = {};

  /// This chat's own journey path: an existing one from an earlier call,
  /// or from [adopt]; a fresh chain and translator the first time this
  /// chat is asked for.
  ChatJourneyPath forChat(String chatId) => _byChat.putIfAbsent(
    chatId,
    () => ChatJourneyPath(
      chain: JourneyPathChain(writer: writer, kind: kind),
      translator: TeamsTranslator(),
    ),
  );

  /// Gives chat [chatId] a chain already at [tip], recovered from the
  /// record, rather than a fresh one, with [translator] already caught up
  /// to it (a fresh one, when this chat was never seen). Throws a
  /// [StateError] if this chat already has a path.
  void adopt(String chatId, EntryHash tip, {TeamsTranslator? translator}) {
    if (_byChat.containsKey(chatId)) {
      throw StateError('$chatId already has a journey path');
    }
    _byChat[chatId] = ChatJourneyPath(
      chain: JourneyPathChain(writer: writer, kind: kind, tip: tip),
      translator: translator ?? TeamsTranslator(),
    );
  }
}

/// Routes [message] to its own chat's journey path within [paths],
/// starting one the first time its chat is seen, and appends what
/// [TeamsTranslator] returns for it: the one function chat routing goes
/// through.
Future<TurnId?> ingestIntoChat(
  TeamsMessage message, {
  required ChatJourneyPaths paths,
  required EntryHash arrival,
}) {
  final path = paths.forChat(message.conversation);
  return ingestTeamsMessage(
    message,
    translator: path.translator,
    chain: path.chain,
    arrival: arrival,
  );
}
