/// A journey path's own chain of turns, written straight to the journal
/// (RULINGS: each journey path has its own agent loop, and the loop writes
/// conversation turns directly).
///
/// A turn's [TurnId] is its journal entry hash, read back as a [TurnId]:
/// one name for the entry, not a second one derived from it.
library;

import 'dart:async';

import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;
import 'package:is_shapes/is_shapes.dart' show TurnId;

import 'journal_writer.dart';
import 'turn_envelope.dart';

/// Appends nodes to one journey path's chain, in the order asked: a second
/// [append] made before the first returns waits for it, so the chain's
/// appends always follow its true tip rather than racing each other to
/// name it.
final class JourneyPathChain {
  JourneyPathChain({required this.writer, required this.kind, EntryHash? tip})
    : _tip = tip;

  /// Where this chain's entries are sent.
  final JournalWriter writer;

  /// The kind every entry of this chain is sent as.
  final Kind kind;

  EntryHash? _tip;
  Future<void> _queue = Future.value();

  /// The journal entry this chain's next append follows; null before its
  /// first.
  EntryHash? get tip => _tip;

  /// The last turn appended, as a [TurnId]; null before this chain's
  /// first append.
  TurnId? get lastTurn => switch (_tip) {
    final tip? => TurnId.parse(tip.hex),
    null => null,
  };

  /// Appends [node] after the current tip, in an envelope naming
  /// [provenance], and returns its [TurnId].
  Future<TurnId> append(Map<String, Object?> node, TurnProvenance provenance) {
    final result = _queue.then((_) => _appendOne(node, provenance));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<TurnId> _appendOne(
    Map<String, Object?> node,
    TurnProvenance provenance,
  ) async {
    final envelope = TurnEnvelope(node: node, provenance: provenance);
    final entry = await writer.append(kind, _tip, envelope.encode());
    _tip = entry;
    return TurnId.parse(entry.hex)!;
  }
}
