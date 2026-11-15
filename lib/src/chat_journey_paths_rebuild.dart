/// Rebuilds [ChatJourneyPaths] from the record on restart: "the record is
/// the only history" (RULINGS) means nothing local is trusted, so this
/// replays every `turn` and `witnessed` entry from the start, through the
/// read socket's own `caught-up` marker, rather than guess where history
/// ends.
library;

import 'dart:typed_data';

import 'package:is_conversation_shapes/is_conversation_shapes.dart';
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;
import 'package:is_shapes/is_shapes.dart' show ActorId, TurnId;
import 'package:is_teams_module/is_teams_module.dart';

import 'chat_journey_paths.dart';
import 'journal_reader.dart';
import 'turn_envelope.dart';

/// A witnessed entry [rebuildChatJourneyPaths] found no turn for: its
/// hash (what `FromArrival` would have named) and its body (what
/// `ingestWitnessedArrival` needs to act on it).
final class UnhandledArrival {
  const UnhandledArrival({required this.hash, required this.body});

  final EntryHash hash;
  final Uint8List body;
}

/// What replaying history gives back: [paths] now has each chat's chain
/// at its tip and its translator caught up to match; [unhandledArrivals]
/// are every `witnessed` entry seen before `caught-up` that no turn's
/// envelope names as [FromArrival] — ones a live follow of `witnessed`
/// will never send again, since it only starts after this point;
/// [resumeFrom] is where that follow should start from.
/// [handledTeamsMessages] is every `UserSaid` already in the record, by
/// its `SourceMessageId` — seed a `SeenTeamsMessages` with it before
/// going live, so a Teams retry of an activity already turned into a turn
/// is recognised, the same way a restarted process would recognise one.
final class ChatJourneyPathsRebuild {
  const ChatJourneyPathsRebuild({
    required this.unhandledArrivals,
    required this.resumeFrom,
    required this.handledTeamsMessages,
  });

  final List<UnhandledArrival> unhandledArrivals;
  final EntryHash? resumeFrom;
  final Set<SourceMessageId> handledTeamsMessages;
}

/// Replays [turnKind] and [witnessedKind] entries from the start of the
/// record, into [paths], through `caught-up`. Call this once, against a
/// freshly constructed, empty [paths], before anything else touches it.
///
/// A chat's chain root — the one entry in it that follows nothing — is
/// always the [TeamsConversation] `ingestTeamsMessage` appends for that
/// chat's first message, so it alone is enough to learn which chat a
/// chain belongs to; every later node in the chain replays onto that
/// chat's own [TeamsTranslator], the same way [ingestTeamsMessage] builds
/// it live, so a restarted translator ends up exactly where the one
/// before it left off.
Future<ChatJourneyPathsRebuild> rebuildChatJourneyPaths(
  JournalReader reader,
  ChatJourneyPaths paths, {
  required Kind turnKind,
  required Kind witnessedKind,
}) async {
  final rootOfEntry = <EntryHash, EntryHash>{};
  final tipOfRoot = <EntryHash, EntryHash>{};
  final chatOfRoot = <EntryHash, String>{};
  final translatorOfRoot = <EntryHash, TeamsTranslator>{};
  final handledArrivals = <EntryHash>{};
  final handledTeamsMessages = <SourceMessageId>{};
  final seenArrivals = <UnhandledArrival>[];
  EntryHash? resumeFrom;

  await for (final item in reader.follow(kinds: {turnKind, witnessedKind})) {
    switch (item) {
      case CaughtUp(:final head):
        resumeFrom = head;
      case JournalEntryFrame frame when frame.kind == witnessedKind:
        seenArrivals.add(UnhandledArrival(hash: frame.hash, body: frame.body));
      case JournalEntryFrame frame:
        final root = frame.follows == null
            ? frame.hash
            : rootOfEntry[frame.follows]!;
        rootOfEntry[frame.hash] = root;
        tipOfRoot[root] = frame.hash;
        final translator = translatorOfRoot.putIfAbsent(
          root,
          TeamsTranslator.new,
        );
        final envelope = TurnEnvelope.decode(frame.body);
        if (envelope.provenance case FromArrival(:final arrival)) {
          handledArrivals.add(arrival);
        }
        switch (envelope.node) {
          case {
            'shape': 'TeamsConversation',
            'id': final String id,
            'serviceUrl': final String serviceUrl,
          }:
            final conversation = TeamsConversation(
              id: id,
              serviceUrl: Uri.parse(serviceUrl),
            );
            chatOfRoot[root] = id;
            translator.joined(conversation);
          case {
            'shape': 'UserSaid',
            'author': final String author,
            'source': final String source,
            'text': final String text,
          }:
            final said = SourceMessageId.parse(source)!;
            translator.heard(
              TurnId.parse(frame.hash.hex)!,
              UserSaid(
                author: ActorId.parse(author)!,
                source: said,
                text: text,
              ),
            );
            handledTeamsMessages.add(said);
        }
    }
    if (resumeFrom != null) break;
  }

  for (final MapEntry(key: root, value: chatId) in chatOfRoot.entries) {
    paths.adopt(chatId, tipOfRoot[root]!, translator: translatorOfRoot[root]);
  }

  return ChatJourneyPathsRebuild(
    unhandledArrivals: [
      for (final arrival in seenArrivals)
        if (!handledArrivals.contains(arrival.hash)) arrival,
    ],
    resumeFrom: resumeFrom,
    handledTeamsMessages: handledTeamsMessages,
  );
}
