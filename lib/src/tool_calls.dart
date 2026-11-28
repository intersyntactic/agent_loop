/// How the model's own tool calls meet a trajectory's given tools: the
/// tools it is offered ([offeredTools]), the tool each call names
/// ([toolCalled]), and what it hears back about a fetch ([fetchResult]).
///
/// What the model hears is the loop's to decide, since only it knows what
/// success means for each kind of action. One rule holds for every kind:
/// [ToolRefused] comes only from [NothingRan], so the model is never told
/// a call was refused when something ran.
library;

import 'dart:convert' show jsonEncode;

import 'package:checked_json/checked_json.dart' show JsonFieldException;
import 'package:is_effects/is_effects.dart'
    show
        BytesBody,
        NoBody,
        NothingRan,
        Outcome,
        Ran,
        StoppedPartway,
        TextBody,
        WebResponse;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show
        IllFormedName,
        OfferedTool,
        ToolCall,
        ToolFailed,
        ToolName,
        ToolRan,
        ToolRefused,
        ToolResult,
        WellFormedName;

import 'package:is_tool_definition_vocabulary/is_tool_definition_vocabulary.dart'
    show OneActionTool;

/// [tools] as the model is shown them: name, description and input schema
/// only. A tool's action, such as the address it fetches and who it goes
/// as, is a person's choice and never reaches the model.
List<OfferedTool> offeredTools(Iterable<OneActionTool> tools) => [
  for (final tool in tools) tool.offered,
];

/// Whether a call the model made can run: [CallRuns] or [CallCannotRun].
sealed class CallToTool {
  const CallToTool();
}

/// The call names [tool], and its input reads as the tool's input.
final class CallRuns extends CallToTool {
  const CallRuns(this.tool);

  final OneActionTool tool;
}

/// The call can't run, and [result] tells the model why: nothing ran, but
/// nothing was refused either, so it is a [ToolFailed].
final class CallCannotRun extends CallToTool {
  const CallCannotRun(this.result);

  final ToolFailed result;
}

/// The tool among [tools], keyed by name, that [call] names, with its input
/// read by the tool's own [OneActionTool.input]. A name that was never
/// offered, well formed or not, can't run.
CallToTool toolCalled(ToolCall call, Map<ToolName, OneActionTool> tools) {
  final tool = switch (call.name) {
    WellFormedName(:final name) => tools[name],
    IllFormedName() => null,
  };
  if (tool == null) {
    return CallCannotRun(
      ToolFailed('no tool named ${jsonEncode(call.name.asSent)}'),
    );
  }
  try {
    tool.input.read(call.input.object);
    return CallRuns(tool);
  } on JsonFieldException catch (e) {
    return CallCannotRun(ToolFailed("${tool.name}'s input: ${e.message}"));
  }
}

/// What the model hears about a fetch whose outcome is [outcome], or null
/// when the outcome couldn't be read.
ToolResult fetchResult(Outcome<WebResponse>? outcome) => switch (outcome) {
  null => const ToolFailed(
    "its outcome couldn't be read, so it may have run; don't retry it",
  ),
  NothingRan(:final why) => ToolRefused(why),
  StoppedPartway(:final why) => ToolFailed(
    "it stopped partway, so it may have partly happened; don't retry it: "
    '$why',
  ),
  Ran(output: WebResponse(:final status, :final refusedBecause))
      when status < 200 || status > 299 =>
    ToolFailed(
      'the site answered $status: ${refusedBecause ?? 'no reason given'}',
    ),
  Ran(output: WebResponse(body: TextBody(:final text))) => ToolRan(text),
  Ran(output: WebResponse(body: NoBody() || BytesBody())) => const ToolFailed(
    'the site answered with no text',
  ),
};

/// What the model hears about a call the loop never ran: nothing ran, but
/// nothing was refused, so it is a [ToolFailed]. Every call is answered,
/// since a provider refuses a request with a call left unanswered.
const notRun = ToolFailed('it was not run');
