/// A reply to the person who started a trajectory, as two actions through
/// one [Crux.forTheReply]: run the program that translates it into an
/// external system's requests, such as teams_module's
/// `teams-reply-translator`, then send exactly the requests it printed.
/// The loop never builds a request itself, and the airlock decides where
/// each one goes.
library;

import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:is_airlock_api/is_airlock_api.dart'
    show Action, Crux, Done, Executable, Failed, Program, Result;
import 'package:is_effects/is_effects.dart'
    show
        AddressPrefix,
        Args,
        ExecResult,
        Exited,
        Killed,
        ModelUsage,
        ProposedRequest,
        SignIn,
        decodeProposedRequest,
        encodeAddressPrefix;
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;

/// The actions of a reply saying [text], such as the model's answer or why
/// its call was refused, to [replyEndpoint] as [signIn]: [translator] is
/// run on it and prints the requests as one JSON array of is_effects'
/// `encodeProposedRequest`; those are then sent in order. Done with how
/// many were sent; [Failed] when either action is refused, the translator
/// fails, or what it printed is not requests. [turn] and [usage], how full
/// the model's context is when the call reported it, go to the translator
/// for the message's footer, and [trajectory] to what its Close closes.
Action<int> replyActions({
  required Executable translator,
  required String text,
  required ModelUsage? usage,
  required AddressPrefix replyEndpoint,
  required SignIn signIn,
  required TrajectoryId trajectory,
  required int turn,
}) => translator.runOrRefusal(
  translatorArgs(
    text: text,
    usage: usage,
    replyEndpoint: replyEndpoint,
    signIn: signIn,
    trajectory: trajectory,
    turn: turn,
  ),
  then: (ExecResult translated) => switch (translated) {
    Exited(exitCode: 0, :final stdout) => switch (requestsIn(stdout)) {
      (requests: final requests?, why: _) =>
        Program.makeWebRequests.runOrRefusal(
          requests,
          then: (responses) => Done(responses.length),
        ),
      (requests: null, :final why) => Failed(
        '${translator.name} printed no requests: $why',
      ),
    },
    Exited(:final exitCode, :final stderr) => Failed(
      '${translator.name} exited $exitCode: ${stderr.trim()}',
    ),
    Killed(:final why) => Failed('${translator.name} was killed: $why'),
  },
);

/// How a translator is run for [text]: the endpoint, sign-in, trajectory,
/// turn and context as flags, and the text on its stdin.
Args translatorArgs({
  required String text,
  required ModelUsage? usage,
  required AddressPrefix replyEndpoint,
  required SignIn signIn,
  required TrajectoryId trajectory,
  required int turn,
}) => Args([
  '--reply-endpoint',
  jsonEncode(encodeAddressPrefix(replyEndpoint)),
  '--sign-in',
  signIn.name,
  '--trajectory',
  trajectory.hex,
  '--turn',
  '$turn',
  if (usage != null) ...['--context-tokens', '${usage.context}'],
  if (usage?.contextWindow case final window?) ...[
    '--context-window',
    '$window',
  ],
], stdin: text);

/// [printed], a translator's stdout, read as its requests: one JSON array of
/// proposed requests, at least one. Otherwise null, and why.
({List<ProposedRequest>? requests, String? why}) requestsIn(String printed) {
  try {
    return switch (jsonDecode(printed)) {
      [_, ...] && final List<Object?> items => (
        requests: [
          for (final (i, item) in items.indexed)
            decodeProposedRequest(item, 'request $i'),
        ],
        why: null,
      ),
      _ => (requests: null, why: 'not a JSON array with a request in it'),
    };
  } on FormatException catch (e) {
    return (requests: null, why: e.message);
  }
}

/// [result] carried on through [crux] until it is no longer an [Action]:
/// each action a continuation leads to is proposed at the crux's next
/// place.
Future<Result<A>> runToEnd<A>(Result<A> result, Crux crux) async {
  var current = result;
  while (true) {
    switch (current) {
      case Action<A>():
        current = await current.next(crux);
      case Done<A>() || Failed():
        return current;
    }
  }
}
