/// Renders a trajectory's turns into the one flattened plain-text body a
/// model request's `request` takes: `claude -p` cannot take prior assistant
/// turns as structured input, so the whole trajectory goes in as one text,
/// the system prompt as a separate argument this does not produce.
library;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show UserSaid;

import 'turn_envelope.dart';

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
    // wire-ok: is_conversation_shapes 0.8.2 has no ReplyText.fromJson yet;
    // read the field directly until it does.
    'ReplyText' => 'Agent: ${json.string('text')}',
    final shape => throw FormatException('cannot render node shape: $shape'),
  };
}
