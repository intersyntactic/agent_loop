/// A given tool's one action as the airlock runs it: each kind of
/// [ToolAction] maps to its program, so a kind added to
/// is_tool_definition_vocabulary fails to compile here until it has one.
library;

import 'package:is_airlock_api/is_airlock_api.dart'
    show Action, Done, Program, WebFetch;
import 'package:is_effects/is_effects.dart' show BodyToKeep;
import 'package:is_tool_definition_vocabulary/is_tool_definition_vocabulary.dart'
    show Fetch, OneActionTool, ToolAction;

/// The action that runs [tool]'s step, done once its outcome is in: what
/// it came to is read back from the logbook, never from here.
Action<()> toolAction(OneActionTool tool) => switch (tool.action) {
  Fetch(:final origin, :final path, :final signIn) => Program.fetch.run(
    WebFetch(origin, path: path, signIn: signIn, keep: BodyToKeep.text),
    then: (_) => const Done(()),
  ),
};
