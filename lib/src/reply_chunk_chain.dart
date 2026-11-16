/// A reply's own chain of chunks, separate from its journey path's chain
/// (RULINGS: "a journey path's chain... holds only that loop's turns; each
/// event and the airlock's entries have chains of their own and refer to
/// others by hash"). A chunk isn't a turn and has no [TurnId]: the turn that
/// closes a streamed reply names this chain's tip by hash instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;

import 'journal_writer.dart';

/// Appends chunks of one streamed reply, in the order asked: a second
/// [append] made before the first returns waits for it, so the chain's
/// appends always follow its true tip rather than racing each other to
/// name it.
final class ReplyChunkChain {
  ReplyChunkChain({required this.writer, required this.kind});

  /// Where this chain's entries are sent.
  final JournalWriter writer;

  /// The kind every entry of this chain is sent as.
  final Kind kind;

  EntryHash? _tip;
  Future<void> _queue = Future.value();

  /// The journal entry this chain's next append follows; null before its
  /// first.
  EntryHash? get tip => _tip;

  /// Appends [node] after the current tip, and returns its entry hash.
  Future<EntryHash> append(Map<String, Object?> node) {
    final result = _queue.then((_) => _appendOne(node));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<EntryHash> _appendOne(Map<String, Object?> node) async {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(node)));
    final entry = await writer.append(kind, _tip, bytes);
    _tip = entry;
    return entry;
  }
}
