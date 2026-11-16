/// Appends entries to one journal, over `is_journal_client`'s write socket
/// client: one connection, one request — a kind, the entry before it in
/// its chain, and its bytes — one line back.
///
/// Keeps the shape [JourneyPathChain] and [ReplyChunkChain] already call
/// (an [EntryHash] back, or a thrown failure) rather than
/// `is_journal_client`'s own result-returning [WriteResult], so neither
/// needed to change when this moved off a hand-rolled socket client.
library;

import 'package:is_journal_client/is_journal_client.dart' as client;
import 'package:is_journal_client/is_journal_client.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;

/// Either the service couldn't be reached ([JournalUnreachable]), or it
/// was reached but refused the entry ([JournalWriteRefused]).
sealed class JournalWriteFailure implements Exception {
  const JournalWriteFailure(this.why);

  final String why;

  @override
  String toString() => '$runtimeType: $why';
}

/// The socket at [JournalWriter.socketPath] could not be reached, closed
/// before answering, or answered something `is_journal_client` doesn't
/// read as a result.
final class JournalUnreachable extends JournalWriteFailure {
  const JournalUnreachable(super.why);
}

/// The service answered `refused`, or added the entry but wasn't sure it
/// kept.
final class JournalWriteRefused extends JournalWriteFailure {
  const JournalWriteRefused(super.why);
}

/// Appends entries to one journal, over the Unix socket its
/// `JournalService` listens on.
final class JournalWriter {
  JournalWriter(this.socketPath) : _client = client.JournalWriter(socketPath);

  final String socketPath;
  final client.JournalWriter _client;

  /// Sends [rest] as an entry of [kind], after [previous] in its chain (or
  /// starting a chain when it is null), and returns the hash the service
  /// gave it. Throws [JournalUnreachable] if the socket can't be reached,
  /// closes before answering, or answers something unreadable;
  /// [JournalWriteRefused] if the service refuses the entry — the tip
  /// named has moved on, the kind isn't allowed for this sender — or the
  /// write failed partway, with the entry's fate unknown.
  Future<EntryHash> append(
    Kind kind,
    EntryHash? previous,
    List<int> rest,
  ) async {
    final result = await _client.write(kind, rest, previous: previous);
    return switch (result) {
      client.Written(:final entry) => entry,
      client.NotTip(:final tip) => throw JournalWriteRefused(
        'not the tip, which is ${tip.hex}',
      ),
      client.WriteRefused(:final why) => throw JournalWriteRefused(why),
      client.WriteFailed(:final why) => throw JournalWriteRefused(why),
      client.Unanswered(:final why) => throw JournalUnreachable(why),
    };
  }
}
