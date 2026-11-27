// The sender table a test logbook runs with, built from KindTheLoopWrites
// so a test can never grant the loop a kind the live table doesn't.
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart' show KindTheLoopWrites;
import 'package:is_logbook/service.dart' show SenderTable;

/// [uid] may write every kind the loop writes, as the live table grants
/// `loop-N`, plus [standIns]: the kinds the test writes in place of the
/// programs that write them live, such as an assignment or an outcome.
SenderTable loopSenderTable(
  String uid, {
  List<String> standIns = const [],
}) => SenderTable.parse(
  Uint8List.fromList(
    '$uid ${[for (final k in KindTheLoopWrites.values) k.wireName, ...standIns].join(' ')}\n'
        .codeUnits,
  ),
);
