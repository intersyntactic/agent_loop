/// A reply's own chain of chunks, separate from its journey path's chain
/// (RULINGS: "a journey path's chain... holds only that loop's turns; each
/// event and the airlock's entries have chains of their own and refer to
/// others by hash"). A chunk isn't a turn and has no [TurnId]: the turn that
/// closes a streamed reply names this chain's tip by hash instead.
///
/// The chain's first entry carries [rootedAt], the journey path's own
/// chain's tip at the moment streaming started: nothing else ties an
/// unfinished chunk chain to a path. Without it, a reply cut short by a
/// restart is never tied to any path in the record, and anything showing a
/// stream live (loop_launcher's router, the app) can't tell which
/// conversation a chunk belongs to until the chain closes (found by
/// loop-launcher-5b, 16 Nov).
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
  ReplyChunkChain({
    required this.writer,
    required this.kind,
    required this.rootedAt,
  });

  /// Where this chain's entries are sent.
  final JournalWriter writer;

  /// The kind every entry of this chain is sent as.
  final Kind kind;

  /// The journey path's own chain's tip when this reply started streaming,
  /// named by hash in this chain's first entry.
  final EntryHash rootedAt;

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
    // Only the chain's root entry needs rootedAt, so only it gets wrapped;
    // every later entry stays a bare node, the same as before this chain
    // had a root to carry. Keeping provenance-like facts off the node
    // itself matches TurnEnvelope's own reason to exist (RULINGS: "where a
    // turn came from goes in the loop's envelope around the node, never in
    // the node's shape").
    final body = _tip == null ? {'node': node, 'rootedAt': rootedAt.hex} : node;
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    final entry = await writer.append(kind, _tip, bytes);
    _tip = entry;
    return entry;
  }
}
