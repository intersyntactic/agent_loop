/// A reply's own chain of chunks, separate from its trajectory's chain:
/// each role keeps its own chain and refers to others by hash, rather than
/// sharing one. A chunk isn't a turn and has no turn id of its own: the
/// turn that closes a streamed reply names this chain's tip by hash
/// instead.
///
/// The chain's first entry is an attached root: its body's first line names
/// [parent], the trajectory's own chain's tip at the moment streaming
/// started, as 64 lowercase hex characters and a newline, before the node
/// that follows. The logbook checks that [parent] is on an entry its sender
/// owns and gives this chain to the same trajectory, refusing otherwise
/// (`no-parent`, `unknown (hash)`, `parent-unowned`, `not-owner`) —
/// enforced by the service, not trusted from a body's own claim.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart' show ObjectId;

import 'logbook_writer.dart';

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
  final LogbookWriter writer;

  /// The kind every entry of this chain is sent as. Must be registered as
  /// an attaching kind (`started`'s body) for the logbook to treat this
  /// chain's root as attached rather than refusing it as ownerless.
  final Kind kind;

  /// The trajectory's own chain's tip when this reply started streaming:
  /// the entry this chain's root attaches to.
  final ObjectId parent;

  ObjectId? _tip;
  Future<void> _queue = Future.value();

  /// The logbook entry this chain's next append follows; null before its
  /// first.
  ObjectId? get tip => _tip;

  /// Appends [node] after the current tip, and returns its entry id.
  Future<ObjectId> append(Map<String, Object?> node) {
    final result = _queue.then((_) => _appendOne(node));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ObjectId> _appendOne(Map<String, Object?> node) async {
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
