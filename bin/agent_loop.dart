/// The loop's entry point: run as `agent-loop@<loop-user>`, one per
/// trajectory, with no arguments of its own beyond the two record sockets
/// (RULINGS: a loop gets no sign-in and no network; the airlock makes the
/// model call). It finds its own assignment in the record rather than being
/// told its trajectory (infra's polkit can start only named template
/// units, so loop_launcher can pass no per-trajectory argument), follows
/// its trajectory's turns live, and records a model request after every
/// [UserSaid] — the proposal a crux will later decide and carry out. It
/// does not reach the crux itself: that invocation is still open
/// (task 10, Nick's call), so this stops at the record, same as
/// `recordModelRequest` always has.
library;

import 'dart:io';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show UserSaid;
import 'package:is_logbook/service.dart' show Kind;
import 'package:is_logbook_client/is_logbook_client.dart'
    show EntryHash, LogbookReader;

/// Until the tool-intent-as-text design lands (task 10), a fixed, labelled
/// placeholder: enough to exercise recording for real, not what the demo's
/// system prompt will actually say.
const _placeholderSystemPrompt =
    'You are the agent in this conversation. Reply in plain text; no tools '
    'are available.';

const _turnKind = 'turn';

Future<void> main(List<String> args) async {
  final options = _Options.parse(args);
  if (options == null) {
    stderr.writeln(
      'usage: agent_loop --record-read <socket> --record-write <socket>',
    );
    exitCode = 64; // EX_USAGE
    return;
  }

  final loopUser = Process.runSync('id', ['-un']).stdout.toString().trim();
  stdout.writeln(
    'agent_loop: ready loopUser=$loopUser '
    'read=${options.recordRead} write=${options.recordWrite}',
  );

  final reader = LogbookReader(options.recordRead);
  final EntryHash root;
  try {
    root = await findTrajectoryRoot(reader, loopUser: loopUser);
  } on NoTrajectoryAssigned catch (e) {
    stderr.writeln('agent_loop: $e');
    exitCode = 1;
    return;
  }
  stdout.writeln('agent_loop: assigned root=${root.hex}');

  final writer = LogbookWriter(options.recordWrite);
  final turnKind = Kind.parse(_turnKind)!;
  final chain = TrajectoryChain(writer: writer, kind: turnKind, tip: root);

  final history = <TurnEnvelope>[];
  final historyHashes = <EntryHash>[];
  await for (final (hash, turn) in followTrajectory(
    reader,
    kind: turnKind,
    chainRoot: root,
  )) {
    history.add(turn);
    historyHashes.add(hash);
    if (turn.node['shape'] != UserSaid.shapeName) continue;

    final request = renderRequestBody(history);
    final requestHash = await recordModelRequestOnTrajectory(
      chain,
      systemPrompt: _placeholderSystemPrompt,
      request: request,
      builtFrom: historyHashes,
    );
    stdout.writeln('agent_loop: recorded model-request ${requestHash.hex}');
  }
}

final class _Options {
  const _Options({required this.recordRead, required this.recordWrite});

  final String recordRead;
  final String recordWrite;

  static _Options? parse(List<String> args) {
    String? recordRead;
    String? recordWrite;
    for (var i = 0; i < args.length; i++) {
      switch (args[i]) {
        case '--record-read' when i + 1 < args.length:
          recordRead = args[++i];
        case '--record-write' when i + 1 < args.length:
          recordWrite = args[++i];
        default:
          return null;
      }
    }
    return recordRead != null && recordWrite != null
        ? _Options(recordRead: recordRead, recordWrite: recordWrite)
        : null;
  }
}
