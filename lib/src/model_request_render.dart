/// Renders a journey path's turns into the one flattened plain-text body
/// `recordModelRequest`'s `request` takes (the render target settled 2026-11-17:
/// `claude -p` cannot take prior assistant turns as structured input, so the
/// whole trajectory goes in as one text, the system prompt as a separate
/// argument this does not produce).
library;

import 'dart:async' show StreamIterator;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show UserSaid;
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;

import 'journal_reader.dart';
import 'turn_envelope.dart';

/// Every turn on the chain ending at [tip], oldest first: walks
/// [JournalEntryFrame.previous] back from [tip] through the backlog
/// [JournalReader.subscribe] delivers for [turnKind], then stops reading
/// once that backlog has caught up. Throws [JournalReadRefused] if [tip],
/// or an entry it names as `previous`, never appears in that backlog.
Future<List<TurnEnvelope>> turnsUpTo(
  JournalReader reader, {
  required Kind turnKind,
  required EntryHash tip,
}) async {
  final byHash = <EntryHash, JournalEntryFrame>{};
  final frames = StreamIterator(reader.subscribe(kinds: {turnKind}));
  try {
    while (await frames.moveNext()) {
      final item = frames.current;
      if (item is CaughtUp) break;
      final frame = item as JournalEntryFrame;
      byHash[frame.hash] = frame;
    }
  } finally {
    await frames.cancel();
  }

  final ordered = <TurnEnvelope>[];
  EntryHash? at = tip;
  while (at != null) {
    final frame =
        byHash[at] ?? (throw JournalReadRefused('turn not found: ${at.hex}'));
    ordered.add(TurnEnvelope.decode(frame.body));
    at = frame.previous;
  }
  return ordered.reversed.toList();
}

/// [turns], oldest first, as one plain-text body: one line per turn, naming
/// who said what. Throws [FormatException] for a turn whose node shape it
/// doesn't know how to render.
String renderRequestBody(List<TurnEnvelope> turns) =>
    turns.map((turn) => _renderLine(turn.node)).join('\n');

String _renderLine(Map<String, Object?> node) {
  final json =
      JsonObject.parse(node) ??
      (throw const FormatException('a turn node must be a JSON object'));
  return switch (json.string('shape')) {
    UserSaid.shapeName => 'User: ${UserSaid.fromJson(json).text}',
    // wire-ok: is_conversation_shapes 0.8.2 has no ReplyText.fromJson yet
    // (flagged to airlock-api-04/intersyntactic-a8, 2026-11-18); read the
    // field directly until it does.
    'ReplyText' => 'Agent: ${json.string('text')}',
    final shape => throw FormatException('cannot render node shape: $shape'),
  };
}
