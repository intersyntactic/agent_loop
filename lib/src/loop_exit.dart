/// How the loop's process ends, as a sysexits code, so its service manager
/// restarts it only when a restart can help.
///
/// Only [tempFail] is worth restarting: the others either come back the
/// same way (a bug, a bad history, a refused permission) or belong to
/// loop_launcher, which starts live loops again itself when it returns.
library;

import 'package:is_logbook_client/is_logbook_client.dart'
    show ReadBroken, ReadFailure, ReadRefused, ReadUnreachable;

import 'logbook_writer.dart';
import 'trajectory_chain.dart' show NoTrajectoryAssigned;

/// One way the loop's process ends, and the exit code it ends with.
enum LoopExit {
  /// The command line was wrong.
  usage(64),

  /// A logbook feed the loop follows ended or couldn't be reached, or
  /// no trajectory is assigned to this loop user: loop_launcher's to
  /// restart, not the service manager's.
  unavailable(69),

  /// A bug, or a history the loop can't read: a restart replays the same
  /// history into the same failure.
  software(70),

  /// A logbook write whose fate is unknown: a restart reads the chain's
  /// tip again and carries on from what landed.
  tempFail(75),

  /// The logbook refused what this loop user sent: its permissions are
  /// wrong, and a restart is refused the same way.
  config(78);

  const LoopExit(this.code);

  /// The process's exit code.
  final int code;

  /// How a loop that failed with [error] ends.
  static LoopExit forFailure(Object error) => switch (error) {
    FeedEnded() || NoTrajectoryAssigned() => unavailable,
    ReadFailure() => switch (error) {
      ReadUnreachable() => unavailable,
      ReadRefused() => config,
      ReadBroken() => software,
    },
    LogbookWriteUncertain() => tempFail,
    // A tip named means another writer moved this loop's own chain: two
    // loops on one trajectory, not a permission.
    LogbookWriteRefused(tip: _?) => software,
    LogbookWriteRefused() => config,
    _ => software,
  };
}

/// A logbook feed the loop follows ended: the logbook's read side, or
/// loop_launcher's feed in front of it, went away.
final class FeedEnded implements Exception {
  const FeedEnded(this.feed);

  /// Which feed ended, for the log.
  final String feed;

  @override
  String toString() => 'FeedEnded: $feed ended';
}
