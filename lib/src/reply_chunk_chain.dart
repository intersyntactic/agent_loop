/// A reply's own chain of chunks, separate from its journey path's chain
/// (RULINGS: "a journey path's chain... holds only that loop's turns; each
/// event and the airlock's entries have chains of their own and refer to
/// others by hash"). A chunk isn't a turn and has no [TurnId]: the turn that
/// closes a streamed reply names this chain's tip by hash instead.
///
/// The chain's first entry is an attached root (is_journal 0.8.0,
/// journal-0f, 16 Nov): its body's first line names [parent], the journey
/// path's own chain's tip at the moment streaming started, as 64 lowercase
/// hex characters and a newline, before the node that follows. The journal
/// checks that [parent] is on an entry its sender owns and gives this
/// chain to the same path, refusing otherwise (`no-parent`, `unknown
/// (hash)`, `parent-unowned`, `not-owner`) — enforced by the service, not
/// trusted from a body's own claim, unlike the JSON-embedded field this
/// replaced.
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
    required this.parent,
  });

  /// Where this chain's entries are sent.
  final JournalWriter writer;

  /// The kind every entry of this chain is sent as. Must be registered as
  /// an attaching kind (`started`'s body) for the journal to treat this
  /// chain's root as attached rather than refusing it as ownerless.
  final Kind kind;

  /// The journey path's own chain's tip when this reply started streaming:
  /// the entry this chain's root attaches to.
  final EntryHash parent;

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
    final nodeBytes = utf8.encode(jsonEncode(node));
    // Only the chain's root names a parent, as the body's first line; a
    // later entry chains onto the root by `previous` instead, the same as
    // any other entry.
    final bytes = _tip == null
        ? Uint8List.fromList([...ascii.encode('${parent.hex}\n'), ...nodeBytes])
        : Uint8List.fromList(nodeBytes);
    final entry = await writer.append(kind, _tip, bytes);
    _tip = entry;
    return entry;
  }
}
