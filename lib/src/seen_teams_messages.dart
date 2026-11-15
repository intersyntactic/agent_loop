/// Which Teams messages already have a `UserSaid`, by `SourceMessageId` —
/// unique across every chat, since it already carries the conversation id
/// (`is_teams_module`'s own `TeamsTranslator`). Teams may witness the same
/// activity twice: the relay forgets what it has seen when it restarts, and
/// a witness that failed partway is retried. Seed this from the record
/// (`rebuildChatJourneyPaths`'s `handledTeamsMessages`) before going live,
/// so a retry never becomes a second turn — "the record is the only
/// history" (RULINGS) applies to this set too, not just to chain tips.
library;

import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show SourceMessageId;

final class SeenTeamsMessages {
  SeenTeamsMessages([Iterable<SourceMessageId> seed = const []])
    : _seen = {...seed};

  final Set<SourceMessageId> _seen;

  bool contains(SourceMessageId source) => _seen.contains(source);

  void add(SourceMessageId source) => _seen.add(source);
}
