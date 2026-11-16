/// A client for the journal service's read socket
/// (`package:is_journal/service.dart`'s `JournalService`, started with a
/// `readSocket`): read-only, and separate from the write socket
/// [JournalWriter] speaks.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;

/// Either the service couldn't be reached ([JournalReadUnreachable]), or it
/// was reached but refused the request ([JournalReadRefused]).
sealed class JournalReadFailure implements Exception {
  const JournalReadFailure(this.why);

  final String why;

  @override
  String toString() => '$runtimeType: $why';
}

/// The socket at [JournalReader.socketPath] could not be reached, or
/// closed before answering.
final class JournalReadUnreachable extends JournalReadFailure {
  const JournalReadUnreachable(super.why);
}

/// The service answered `refused`, or something that isn't a frame or the
/// line a request expects.
final class JournalReadRefused extends JournalReadFailure {
  const JournalReadRefused(super.why);
}

/// One item a `subscribe` sends: an entry ([JournalEntryFrame]), or the
/// marker between its backlog and its live entries ([CaughtUp]).
sealed class SubscribedItem {
  const SubscribedItem();
}

/// Marks where a `subscribe`'s backlog ended: [head] is the journal's last
/// entry of any kind at that point (null for an empty journal) — a valid
/// point to [JournalReader.subscribe] from next time, whether or not
/// anything of that subscription's own kinds came after it. Sent once,
/// between entries, in the same synchronous step as the switch to live
/// ones.
final class CaughtUp extends SubscribedItem {
  const CaughtUp(this.head);

  final EntryHash? head;
}

/// One entry as the read socket sends it: its hash, kind, the entry before
/// it in its chain, and its object bytes exactly as recorded — the
/// `<kind>\n<previous>\n` header included, the same bytes [EntryHash.of]
/// hashes and `JournalWriter.append` wrote.
final class JournalEntryFrame extends SubscribedItem {
  const JournalEntryFrame({
    required this.hash,
    required this.kind,
    required this.previous,
    required this.bytes,
  });

  final EntryHash hash;
  final Kind kind;
  final EntryHash? previous;
  final Uint8List bytes;

  /// [bytes] without the `<kind>\n<previous>\n` header: what was passed to
  /// [JournalWriter.append] as `rest`.
  Uint8List get body {
    final first = bytes.indexOf(0x0a);
    final second = bytes.indexOf(0x0a, first + 1);
    return Uint8List.sublistView(bytes, second + 1);
  }
}

/// Reads one journal's entries, over the Unix socket its `JournalService`
/// listens for readers on.
final class JournalReader {
  const JournalReader(this.socketPath);

  final String socketPath;

  /// The current tip of the chain [entry] is in. Throws
  /// [JournalReadUnreachable] if the socket can't be reached or closes
  /// before answering, [JournalReadRefused] if [entry] names no chain the
  /// service knows.
  Future<EntryHash> tipOf(EntryHash entry) async {
    final Socket socket;
    try {
      socket = await _connect();
    } on Exception catch (e) {
      throw JournalReadUnreachable('$e');
    }
    try {
      socket.add(utf8.encode('tip ${entry.hex}\n'));
      await socket.flush();
      final line = await _readLine(socket);
      if (line == null) {
        throw const JournalReadUnreachable('closed before a response');
      }
      if (line.startsWith('tip ')) {
        final hash = EntryHash.parse(line.substring(4));
        if (hash == null) throw JournalReadRefused('not a hash: $line');
        return hash;
      }
      throw JournalReadRefused(_refusalOf(line));
    } on JournalReadFailure {
      rethrow;
    } on Exception catch (e) {
      throw JournalReadUnreachable('$e');
    } finally {
      socket.destroy();
    }
  }

  /// Every entry of [kinds] (every kind, when empty) after [after] (the
  /// journal's start, when null), a [CaughtUp] marking where that backlog
  /// ended, then each new entry as it is added, until the stream is
  /// cancelled. Errors with [JournalReadUnreachable] if the socket can't
  /// be reached, [JournalReadRefused] if [after] names no entry the
  /// service knows.
  Stream<SubscribedItem> subscribe({
    Set<Kind> kinds = const {},
    EntryHash? after,
  }) {
    late StreamController<SubscribedItem> controller;
    Socket? socket;
    final parser = _FrameParser();

    Future<void> start() async {
      try {
        socket = await _connect();
      } on Exception catch (e) {
        controller.addError(JournalReadUnreachable('$e'));
        await controller.close();
        return;
      }
      final kindsText = kinds.isEmpty ? '*' : kinds.map((k) => '$k').join(',');
      socket!.add(
        utf8.encode('subscribe $kindsText from ${after?.hex ?? 'start'}\n'),
      );
      late StreamSubscription<Uint8List> subscription;
      subscription = socket!.listen(
        (chunk) {
          try {
            for (final item in parser.addChunk(chunk)) {
              switch (item) {
                case SubscribedItem item:
                  controller.add(item);
                case String refusal:
                  controller.addError(JournalReadRefused(_refusalOf(refusal)));
              }
            }
          } on FormatException catch (e) {
            // A bad header leaves the parser unable to find its place in
            // the byte stream again (frames are counted, not delimited),
            // so the stream can't continue: end it rather than let every
            // later frame come out as a lost error forever.
            controller.addError(JournalReadRefused('$e'));
            subscription.cancel();
            socket!.destroy();
            controller.close();
          }
        },
        onDone: controller.close,
        onError: (Object e) =>
            controller.addError(JournalReadUnreachable('$e')),
        cancelOnError: false,
      );
    }

    controller = StreamController<SubscribedItem>(
      onListen: start,
      onCancel: () => socket?.destroy(),
    );
    return controller.stream;
  }

  Future<Socket> _connect() => Socket.connect(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );

  static String _refusalOf(String line) =>
      line.startsWith('refused ') ? line.substring(8) : line;

  static Future<String?> _readLine(Socket socket) async {
    final buffer = <int>[];
    await for (final chunk in socket) {
      for (final byte in chunk) {
        if (byte == 0x0a) return ascii.decode(buffer, allowInvalid: true);
        buffer.add(byte);
      }
    }
    return null;
  }
}

/// Parses the read socket's own framing from raw chunks: a header line
/// (`entry <hash> <kind> <previous> <length>`, `caught-up <head>`, or a
/// bare `refused ...`), then, for an entry, exactly `<length>` more bytes
/// — never split on lines, since a body need not end in one and may hold
/// one of its own.
final class _FrameParser {
  final _buf = <int>[];
  _PendingHeader? _pending;

  Iterable<Object> addChunk(Uint8List chunk) sync* {
    _buf.addAll(chunk);
    while (true) {
      if (_pending == null) {
        final nl = _buf.indexOf(0x0a);
        if (nl < 0) return;
        final line = ascii.decode(_buf.sublist(0, nl), allowInvalid: true);
        _buf.removeRange(0, nl + 1);
        if (line.startsWith('caught-up ')) {
          final head = line.substring('caught-up '.length);
          yield CaughtUp(head == 'start' ? null : EntryHash.parse(head));
          continue;
        }
        if (!line.startsWith('entry ')) {
          yield line;
          continue;
        }
        _pending = _PendingHeader.parse(line);
      }
      final pending = _pending!;
      if (_buf.length < pending.length) return;
      final bytes = Uint8List.fromList(_buf.sublist(0, pending.length));
      _buf.removeRange(0, pending.length);
      _pending = null;
      yield JournalEntryFrame(
        hash: pending.hash,
        kind: pending.kind,
        previous: pending.previous,
        bytes: bytes,
      );
    }
  }
}

final class _PendingHeader {
  const _PendingHeader(this.hash, this.kind, this.previous, this.length);

  final EntryHash hash;
  final Kind kind;
  final EntryHash? previous;
  final int length;

  static _PendingHeader parse(String line) {
    final words = line.split(' ');
    if (words.length != 5) throw FormatException('not an entry frame: $line');
    final hash = EntryHash.parse(words[1]);
    final kind = words[2] == Kind.started.name
        ? Kind.started
        : Kind.parse(words[2]);
    final previous = words[3] == '-' ? null : EntryHash.parse(words[3]);
    final length = int.tryParse(words[4]);
    if (hash == null || kind == null || length == null) {
      throw FormatException('not an entry frame: $line');
    }
    return _PendingHeader(hash, kind, previous, length);
  }
}
