/// A model request's `request`, as the turns it carries: a JSON array of
/// Responses API input items, one per turn, each a user's or the agent's.
/// The system prompt travels separately, so no item here is a system one.
/// Each driver turns the array into what its own provider takes.
library;

import 'dart:convert' show jsonEncode;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    show UserSaid;

import 'turn_envelope.dart';

/// Who said a [ModelInputTurn].
enum ModelInputRole { user, assistant }

/// One turn of a model request: [text], said by [role].
final class ModelInputTurn {
  const ModelInputTurn(this.role, this.text);

  final ModelInputRole role;
  final String text;

  Map<String, Object?> toJson() => {'role': role.name, 'content': text};
}

/// [turns], oldest first, as the `request` a model call sends.
String encodeModelInput(List<ModelInputTurn> turns) =>
    jsonEncode([for (final turn in turns) turn.toJson()]);

/// [turn]'s node as an input turn. Throws [FormatException] for a node
/// shape it doesn't know.
ModelInputTurn inputTurnOf(TurnEnvelope turn) {
  final json =
      JsonObject.parse(turn.node) ??
      (throw const FormatException('a turn node must be a JSON object'));
  // is_conversation_shapes 0.8.2 has no ReplyText.fromJson yet, so its
  // field is read directly.
  // wire-ok: a node's shape name, read once here
  return switch (json.string('shape')) {
    UserSaid.shapeName => ModelInputTurn(
      ModelInputRole.user,
      UserSaid.fromJson(json).text,
    ),
    'ReplyText' => ModelInputTurn(
      ModelInputRole.assistant,
      json.string('text'),
    ),
    final shape => throw FormatException(
      'no input turn for node shape: $shape',
    ),
  };
}
