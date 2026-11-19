/// A trajectory's own chain of turns, written to the logbook (the live
/// record service, is_logbook): each trajectory's own agent loop writes
/// its conversation turns directly.
library;

import 'dart:async';
import 'dart:convert' show utf8;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart'
    show CaughtUp, Entry, LogbookReader, ObjectId;

import 'logbook_writer.dart';
import 'turn_envelope.dart';

/// Appends nodes to one trajectory's chain, in the order asked: a second
/// [append] made before the first returns waits for it, so the chain's
/// appends always follow its true tip rather than racing each other to
/// name it.
final class TrajectoryChain {
  TrajectoryChain({required this.writer, required this.kind, this._tip})
    : _tipUnconfirmed = false;

  /// A chain this loop may already have written to in an earlier run,
  /// starting from [root]: its first append follows whatever tip the
  /// service names, once, since only this loop's user writes this chain and
  /// so that tip is this loop's own last entry. Every append after that must
  /// follow the tip this chain tracks itself.
  TrajectoryChain.resumed({
    required this.writer,
    required this.kind,
    required ObjectId root,
  }) : _tip = root,
       _tipUnconfirmed = true;

  /// Where this chain's entries are sent.
  final LogbookWriter writer;

  /// The kind every turn of this chain is sent as.
  final Kind kind;

  ObjectId? _tip;
  bool _tipUnconfirmed;
  Future<void> _queue = Future.value();

  /// The logbook entry this chain's next append follows; null before its
  /// first (never true for a trajectory chain, whose root is the
  /// `users-assigned-to-trajectory` entry [findTrajectoryRoot] returns).
  ObjectId? get tip => _tip;

  /// Appends [node] after the current tip, in an envelope naming
  /// [provenance], and returns the new tip.
  Future<ObjectId> append(
    Map<String, Object?> node,
    TurnProvenance provenance,
  ) {
    final envelope = TurnEnvelope(node: node, provenance: provenance);
    return appendEntry(kind, envelope.encode());
  }

  /// Appends [bytes] after the current tip, as an entry of [entryKind]
  /// rather than this chain's own [kind] — a model request and its pieces,
  /// for instance, share this chain's tip without being turns themselves.
  /// Returns the new entry's hash.
  Future<ObjectId> appendEntry(Kind entryKind, List<int> bytes) {
    final result = _queue.then((_) => _appendEntryOne(entryKind, bytes));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ObjectId> _appendEntryOne(Kind entryKind, List<int> bytes) async {
    final ObjectId entry;
    try {
      entry = await writer.append(entryKind, _tip, bytes);
    } on LogbookWriteRefused catch (e) {
      final serviceTip = e.tip;
      if (!_tipUnconfirmed || serviceTip == null) rethrow;
      _tipUnconfirmed = false;
      _tip = serviceTip;
      return _appendEntryOne(entryKind, bytes);
    }
    _tipUnconfirmed = false;
    _tip = entry;
    return entry;
  }
}

/// The hash of the latest `users-assigned-to-trajectory` entry naming
/// [loopUser] — the one this loop user is currently assigned to, since the
/// service never leaves a loop user assigned to two open trajectories at
/// once (is_logbook's own rule): a later assignment for the same loop user
/// always means an earlier one's mission ended first. That hash is the
/// trajectory's chain root, and the `previous` of its first turn.
///
/// Reads the backlog only, then stops — a loop starts once, against
/// whichever trajectory it is assigned to at that moment. Throws
/// [NoTrajectoryAssigned] if the backlog names no assignment for
/// [loopUser] — a loop started before its assignment was written, not a
/// bug, so a plain [Exception] rather than an [Error].
Future<ObjectId> findTrajectoryRoot(
  LogbookReader reader, {
  required String loopUser,
}) async {
  ObjectId? root;
  final subscription = reader.subscribe(
    kinds: {Kind.usersAssignedToTrajectory},
  );
  await for (final item in subscription) {
    switch (item) {
      case Entry entry:
        if (_loopUserOf(entry.body) == loopUser) root = entry.id;
      case CaughtUp _:
        return root ?? (throw NoTrajectoryAssigned(loopUser));
    }
  }
  return root ?? (throw NoTrajectoryAssigned(loopUser));
}

/// No `users-assigned-to-trajectory` entry in the logbook names [loopUser].
final class NoTrajectoryAssigned implements Exception {
  const NoTrajectoryAssigned(this.loopUser);

  final String loopUser;

  @override
  String toString() => 'no trajectory assigned to $loopUser';
}

/// The `loopUser` field of a `users-assigned-to-trajectory` body, read
/// directly: is_logbook's own `_UsersAssigned.parse` is private to that
/// package, so this reads only the one field it needs, the same way the
/// service's own sender table check does. Null for a body that isn't
/// shaped as one (never this loop's own assignment, so skipped rather than
/// thrown).
String? _loopUserOf(List<int> body) {
  try {
    return JsonObject.decode(utf8.decode(body)).stringOrNull('loopUser');
  } on FormatException {
    return null;
  }
}

/// Every turn on the chain descending from [chainRoot], live, each with its
/// own entry hash (what a later [ModelRequest.builtFrom] names, so it
/// points at the turn actually recorded, not a hash reconstructed from its
/// decoded body — which would not match, since an entry's hash covers its
/// `<kind>\n<previous>\n` header too). Reads the backlog, then every new
/// [kind] entry as it is added, for as long as the stream is listened to.
/// An entry belongs to the chain when its hash is [chainRoot] or its
/// `previous` is already on it — [chainRoot] itself is never yielded (it is
/// an assignment, not a turn).
///
/// Built with [Stream.expand] rather than `async*`: an `async*` generator's
/// own cancel future waits for its next yield, which never comes while a
/// live subscription is idle; `expand` passes a cancel straight through to
/// [LogbookReader]'s own subscription, which is not a generator and
/// cancels at once.
Stream<(ObjectId, TurnEnvelope)> followTrajectory(
  LogbookReader reader, {
  required Kind kind,
  required ObjectId chainRoot,
}) {
  final onChain = <ObjectId>{chainRoot};
  return reader.subscribe(kinds: {kind}).expand((item) {
    if (item is! Entry) return const [];
    final belongs = item.previous != null && onChain.contains(item.previous);
    if (!belongs) return const [];
    onChain.add(item.id);
    return [(item.id, TurnEnvelope.decode(item.body))];
  });
}
