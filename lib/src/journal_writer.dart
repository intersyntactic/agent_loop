/// A client for the journal service's writer, over its Unix socket
/// (`package:is_journal/service.dart`'s `JournalService`): one connection,
/// one request — a kind, the entry it follows, and its bytes — one line
/// back.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;

/// Either the service couldn't be reached ([JournalUnreachable]), or it
/// was reached but refused the entry ([JournalWriteRefused]).
sealed class JournalWriteFailure implements Exception {
  const JournalWriteFailure(this.why);

  final String why;

  @override
  String toString() => '$runtimeType: $why';
}

/// The socket at [JournalWriter.socketPath] could not be reached, or
/// closed before answering.
final class JournalUnreachable extends JournalWriteFailure {
  const JournalUnreachable(super.why);
}

/// The service answered `refused`, or something other than `ok <hash>`.
final class JournalWriteRefused extends JournalWriteFailure {
  const JournalWriteRefused(super.why);
}

/// Appends entries to one journal, over the Unix socket its
/// `JournalService` listens on.
final class JournalWriter {
  const JournalWriter(this.socketPath);

  final String socketPath;

  /// Sends [rest] as an entry of [kind], following [follows] (or starting
  /// a chain when it is null), and returns the hash the service gave it.
  /// Throws [JournalUnreachable] if the socket can't be reached or closes
  /// before answering, [JournalWriteRefused] if the service refuses the
  /// entry — the tip named has moved on, the kind isn't allowed for this
  /// sender, or anything else it answers `refused` to.
  Future<EntryHash> append(
    Kind kind,
    EntryHash? follows,
    Uint8List rest,
  ) async {
    final Socket socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      );
    } on Exception catch (e) {
      throw JournalUnreachable('$e');
    }
    try {
      final header = '$kind\n${follows?.hex ?? '-'}\n';
      socket.add(utf8.encode(header));
      socket.add(rest);
      await socket.close();
      String? line;
      await for (final l
          in utf8.decoder.bind(socket).transform(const LineSplitter())) {
        line = l;
        break;
      }
      if (line == null) {
        throw const JournalUnreachable('closed before a response');
      }
      if (line.startsWith('ok ')) {
        final hash = EntryHash.parse(line.substring(3));
        if (hash == null) throw JournalWriteRefused('not a hash: $line');
        return hash;
      }
      throw JournalWriteRefused(
        line.startsWith('refused ') ? line.substring(8) : line,
      );
    } on JournalWriteFailure {
      rethrow;
    } on Exception catch (e) {
      throw JournalUnreachable('$e');
    } finally {
      socket.destroy();
    }
  }
}
