/// How the model calls a tool when a model call carries text alone: the
/// system prompt shows it each tool's definition and how to call one
/// ([toolsPrompt]), each reply is read with [readModelReply], and a call's
/// result goes back to the model as the next user turn ([toolResultText]).
///
/// One call per reply, and the call ends it, so a turn's steps stay in the
/// order the model asked for them.
library;

import 'dart:convert' show jsonEncode;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_tools_api/is_tools_api.dart' show ToolSpec;

const _callOpen = '<tool_call>';
const _callClose = '</tool_call>';

/// What a model's reply comes to, read from its text.
sealed class ReadModelReply {
  const ReadModelReply();
}

/// The reply answers the message: [text] goes to the person as it is.
final class AnswerText extends ReadModelReply {
  const AnswerText(this.text);

  final String text;
}

/// The reply calls the tool [name] with [input].
final class CallsTool extends ReadModelReply {
  const CallsTool({required this.name, required this.input});

  /// As the model wrote it: a name no tool has is the caller's to refuse.
  final String name;
  final JsonObject input;
}

/// The reply tries to call a tool and the call can't be read, because
/// [why]: the model is told so, as the call's error result, and tries again.
final class ToolCallUnreadable extends ReadModelReply {
  const ToolCallUnreadable(this.why);

  final String why;
}

/// [text], a model's reply, read as an answer or a tool call. Any reply
/// holding `<tool_call>` is a call, read strictly; every other is an answer.
ReadModelReply readModelReply(String text) {
  final start = text.indexOf(_callOpen);
  if (start < 0) return AnswerText(text);
  final bodyStart = start + _callOpen.length;
  final end = text.indexOf(_callClose, bodyStart);
  if (end < 0) return const ToolCallUnreadable('the call has no $_callClose');
  if (text.indexOf(_callOpen, bodyStart) >= 0) {
    return const ToolCallUnreadable(
      'a reply holds one call; this one holds more',
    );
  }
  if (text.substring(end + _callClose.length).trim().isNotEmpty) {
    return const ToolCallUnreadable(
      'the call ends the reply; this one has text after it',
    );
  }
  final JsonObject call;
  try {
    call = JsonObject.decode(text.substring(bodyStart, end));
  } on FormatException catch (e) {
    return ToolCallUnreadable('the call is not a JSON object: ${e.message}');
  }
  // wire-ok: the call's own two keys, read once here
  final extra = call.keys.where((k) => k != 'name' && k != 'input');
  if (extra.isNotEmpty) {
    return ToolCallUnreadable(
      'a call has only "name" and "input", not "${extra.first}"',
    );
  }
  final name = call.raw('name');
  if (name is! String || name.isEmpty) {
    return const ToolCallUnreadable('the call has no "name" string');
  }
  final input = JsonObject.parse(
    call.raw('input') ?? const <String, Object?>{},
  );
  if (input == null) {
    return const ToolCallUnreadable('the call\'s "input" is not an object');
  }
  return CallsTool(name: name, input: input);
}

/// The model's instructions for calling [tools], each shown by its
/// definition; empty when there are none.
String toolsPrompt(List<ToolSpec<Object?, Object?>> tools) {
  if (tools.isEmpty) return '';
  return [
    'You can call these tools. To call one, end your reply with exactly one '
        'call, and nothing after it:',
    '',
    _callOpen,
    '{"name": "<the tool\'s name>", "input": {<what its input_schema asks '
        'for>}}',
    _callClose,
    '',
    'Its result comes back as the next message, inside <tool_result>, or '
        '<tool_result error> when the call failed. Then call another tool or '
        'answer. A reply with no call is your answer to the person.',
    '',
    'The tools:',
    for (final tool in tools) jsonEncode(tool.toJson()),
  ].join('\n');
}

/// A call's result as the model is shown it, the next user turn: [text],
/// marked an error when [isError].
String toolResultText(String text, {required bool isError}) =>
    '${isError ? '<tool_result error>' : '<tool_result>'}\n'
    '$text\n'
    '</tool_result>';
