/// A trajectory's own chain of entries in the logbook (the live logbook
/// service, is_logbook): each trajectory's own agent loop writes its model
/// requests, proposals and summary markers there directly.
library;

import 'dart:async';
import 'dart:convert' show utf8;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_logbook_client/is_logbook_client.dart'
    show CaughtUp, Entry, Kind, LogbookReader, ObjectId;

import 'kind_the_loop_writes.dart';
import 'logbook_writer.dart';

/// Appends entries to one trajectory's chain, in the order asked: a second
/// [appendEntry] made before the first returns waits for it, so the chain's
/// appends always follow its true tip rather than racing each other to
/// name it.
final class TrajectoryChain {
  TrajectoryChain({required this.writer, this._tip}) : _tipUnconfirmed = false;

  /// A chain this loop may already have written to in an earlier run,
  /// starting from [root] until [resumeAfter] names a later entry. Until an
  /// append is newly added, the chain follows whatever tip the service
  /// names: only this loop's user writes this chain, so that tip is this
  /// loop's own last entry. An entry the service already held confirms
  /// nothing, since an earlier run may have written the same bytes after
  /// the same entry anywhere back along the chain. Once one append is newly
  /// added, every later one must follow the tip this chain tracks itself.
  TrajectoryChain.resumed({required this.writer, required ObjectId root})
    : _tip = root,
      _tipUnconfirmed = true;

  /// Where this chain's entries are sent.
  final LogbookWriter writer;

  ObjectId? _tip;
  bool _tipUnconfirmed;
  Future<void> _queue = Future.value();

  /// The logbook entry this chain's next append follows; null before its
  /// first (never true for a trajectory chain, whose root is the
  /// `users-assigned-to-trajectory` entry [findTrajectoryRoot] returns).
  ObjectId? get tip => _tip;

  /// Before a resumed chain's first append is added: [lastSeen] is the
  /// latest of this loop's own entries it has read back, so its first
  /// append follows that rather than the root. Ignored once the tip is
  /// confirmed.
  void resumeAfter(ObjectId lastSeen) {
    if (_tipUnconfirmed) _tip = lastSeen;
  }

  /// Appends [bytes] after the current tip, as an entry of [entryKind].
  /// Returns the new entry's hash.
  Future<ObjectId> appendEntry(KindTheLoopWrites entryKind, List<int> bytes) {
    final result = _queue.then((_) => _appendEntryOne(entryKind.kind, bytes));
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<ObjectId> _appendEntryOne(Kind entryKind, List<int> bytes) async {
    final ({ObjectId entry, bool alreadyRecorded}) written;
    try {
      written = await writer.appendOrFind(entryKind, _tip, bytes);
    } on LogbookWriteRefused catch (e) {
      final serviceTip = e.tip;
      if (!_tipUnconfirmed || serviceTip == null || serviceTip == _tip) {
        rethrow;
      }
      _tip = serviceTip;
      return _appendEntryOne(entryKind, bytes);
    }
    if (!written.alreadyRecorded) _tipUnconfirmed = false;
    _tip = written.entry;
    return written.entry;
  }
}

/// The hash of the latest `users-assigned-to-trajectory` entry naming
/// [loopUser] — the one this loop user is currently assigned to, since the
/// service never leaves a loop user assigned to two open trajectories at
/// once (is_logbook's own rule): a later assignment for the same loop user
/// always means an earlier one's mission ended first. That hash is the
/// trajectory's chain root, and the `previous` of its first entry.
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
