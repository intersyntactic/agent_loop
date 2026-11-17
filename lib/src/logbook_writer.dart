/// Appends entries to one logbook, over `is_logbook_client`'s write socket
/// client: one connection, one request — a kind, the entry before it in
/// its chain, and its bytes — one line back.
///
/// Keeps the same shape [JournalWriter] exposes (an [EntryHash] back, or a
/// thrown failure) rather than `is_logbook_client`'s own result-returning
/// [WriteResult], so [TrajectoryChain] can call either without caring which
/// record service it is writing to.
library;

import 'package:is_logbook_client/is_logbook_client.dart' as client;
import 'package:is_logbook_client/is_logbook_client.dart' show EntryHash;
import 'package:is_logbook/service.dart' show Kind;

/// Either the entry's fate is unknown, so resending it blindly could write
/// it twice ([LogbookWriteUncertain]), or nothing was added at all, so
/// resending is safe ([LogbookWriteRefused]).
sealed class LogbookWriteFailure implements Exception {
  const LogbookWriteFailure(this.why);

  final String why;

  @override
  String toString() => '$runtimeType: $why';
}

/// The entry may or may not be in: the socket couldn't be reached, closed
/// before answering, answered something unreadable, or the write failed
/// partway. Read the chain's tip before sending it again.
final class LogbookWriteUncertain extends LogbookWriteFailure {
  const LogbookWriteUncertain(super.why);
}

/// Nothing was added: the service answered `refused` outright, or named a
/// different tip than [previous]. Safe to send again, naming the tip the
/// service gave if it gave one.
final class LogbookWriteRefused extends LogbookWriteFailure {
  const LogbookWriteRefused(super.why);
}

/// Appends entries to one logbook, over the Unix socket its service
/// listens on.
final class LogbookWriter {
  LogbookWriter(this.socketPath) : _client = client.LogbookWriter(socketPath);

  final String socketPath;
  final client.LogbookWriter _client;

  /// Sends [rest] as an entry of [kind], after [previous] in its chain (or
  /// starting a chain when it is null), and returns the hash the service
  /// gave it. Throws [LogbookWriteRefused] if nothing was added — the tip
  /// named has moved on, or the kind isn't allowed for this sender — safe
  /// to send again; [LogbookWriteUncertain] if the entry's fate isn't
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
      client.NotTip(:final tip) => throw LogbookWriteRefused(
        'not the tip, which is ${tip.hex}',
      ),
      client.WriteRefused(:final why) => throw LogbookWriteRefused(why),
      client.WriteFailed(:final why) => throw LogbookWriteUncertain(why),
      client.Unanswered(:final why) => throw LogbookWriteUncertain(why),
    };
  }
}
