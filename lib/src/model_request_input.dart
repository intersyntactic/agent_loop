/// A turn the loop wrote on its own chain, as a model request carries it:
/// is_model_vocabulary's [ModelTurn], which every driver reads.
library;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_conversation_shapes/is_conversation_shapes.dart'
    as conversation;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show AgentSaid, ModelTurn, UserSaid;

import 'turn_envelope.dart';

/// [turn]'s node as a model turn. Throws [FormatException] for a node
/// shape it doesn't know.
ModelTurn inputTurnOf(TurnEnvelope turn) {
  final json =
      JsonObject.parse(turn.node) ??
      (throw const FormatException('a turn node must be a JSON object'));
  // is_conversation_shapes 0.8.2 has no ReplyText.fromJson yet, so its
  // field is read directly.
  // wire-ok: a node's shape name, read once here
  return switch (json.string('shape')) {
    conversation.UserSaid.shapeName => UserSaid(
      conversation.UserSaid.fromJson(json).text,
    ),
    'ReplyText' => AgentSaid(json.string('text')),
    final shape => throw FormatException(
      'no input turn for node shape: $shape',
    ),
  };
}
