/// Appends entries to one journal, over `is_journal_client`'s write socket
/// client: one connection, one request — a kind, the entry before it in
/// its chain, and its bytes — one line back.
///
/// Keeps the shape [ReplyChunkChain] already calls
/// (an [EntryHash] back, or a thrown failure) rather than
/// `is_journal_client`'s own result-returning [WriteResult], so neither
/// needed to change when this moved off a hand-rolled socket client.
library;

import 'package:is_journal_client/is_journal_client.dart' as client;
import 'package:is_journal_client/is_journal_client.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;

/// Either the entry's fate is unknown, so resending it blindly could write
/// it twice ([JournalWriteUncertain]), or nothing was added at all, so
/// resending is safe ([JournalWriteRefused]). The two must stay apart: a
/// catcher that treats every failure as safe to resend would double an
/// entry whenever this throws [JournalWriteUncertain] (found by
/// journal-client-7e, 16 Nov, reviewing this package's own first cut, which
/// named this case `JournalUnreachable` — wrong once it also covered a
/// request the service did reach and did answer, just uncertainly).
sealed class JournalWriteFailure implements Exception {
  const JournalWriteFailure(this.why);

  final String why;

  @override
  String toString() => '$runtimeType: $why';
}

/// The entry may or may not be in: the socket couldn't be reached, closed
/// before answering, answered something unreadable, or the write failed
/// partway. Read the chain's tip before sending it again.
final class JournalWriteUncertain extends JournalWriteFailure {
  const JournalWriteUncertain(super.why);
}

/// Nothing was added: the service answered `refused` outright, or named a
/// different tip than [previous]. Safe to send again, naming the tip the
/// service gave if it gave one.
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
  /// gave it. Throws [JournalWriteRefused] if nothing was added — the tip
  /// named has moved on, or the kind isn't allowed for this sender — safe
  /// to send again; [JournalWriteUncertain] if the entry's fate isn't
  /// known — the socket couldn't be reached or closed before answering, or
  /// the write failed partway — where resending blindly could write it
  /// twice.
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
      client.WriteFailed(:final why) => throw JournalWriteUncertain(why),
      client.Unanswered(:final why) => throw JournalWriteUncertain(why),
    };
  }
}
