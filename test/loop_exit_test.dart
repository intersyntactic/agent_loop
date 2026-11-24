// Proves which exit code each way the loop fails ends with, so the service
// manager restarts only a write whose fate is unknown.
import 'package:agent_loop/agent_loop.dart';
import 'package:is_logbook_client/is_logbook_client.dart'
    show ObjectId, ReadBroken, ReadRefused, ReadUnreachable;
import 'package:test/test.dart';

void main() {
  final tip = ObjectId.parse('ab' * 32)!;

  final cases = <String, (Object, LoopExit)>{
    'a feed that ended': (const FeedEnded('the history'), LoopExit.unavailable),
    'no trajectory assigned': (
      const NoTrajectoryAssigned('loop-1'),
      LoopExit.unavailable,
    ),
    'an unreachable read socket': (
      const ReadUnreachable('socket: gone'),
      LoopExit.unavailable,
    ),
    'a read the service refused': (
      const ReadRefused('not a reader'),
      LoopExit.config,
    ),
    'a read that does not check': (
      const ReadBroken('bad frame'),
      LoopExit.software,
    ),
    'a write of unknown fate': (
      const LogbookWriteUncertain('closed before answering'),
      LoopExit.tempFail,
    ),
    'a write the service refused': (
      const LogbookWriteRefused('kind not allowed'),
      LoopExit.config,
    ),
    "a write after another writer moved the loop's chain": (
      LogbookWriteRefused('not the tip', tip: tip),
      LoopExit.software,
    ),
    'an unreadable history': (
      const FormatException('not a turn envelope'),
      LoopExit.software,
    ),
    'a broken assumption': (StateError('unresolved Action'), LoopExit.software),
  };

  for (final MapEntry(key: what, value: (error, ending)) in cases.entries) {
    test('$what ends ${ending.name} (${ending.code})', () {
      expect(LoopExit.forFailure(error), ending);
    });
  }

  test("each ending's code is its sysexits code", () {
    expect([for (final e in LoopExit.values) e.code], [64, 69, 70, 75, 78]);
  });
}
