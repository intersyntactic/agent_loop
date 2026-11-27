/// A reply to the person who started a trajectory, as two actions through
/// one [ProposesAtNextPlace.forTheReply]: run the program that draws it as its surface's
/// requests, such as teams_module's `teams-reply-drawing`, then send
/// exactly the requests it printed.
/// The loop never builds a request itself, and the airlock decides where
/// each one goes.
library;

import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:is_airlock_api/is_airlock_api.dart'
    show Action, Done, Executable, Failed, Program, ProposesActions, Result;
import 'package:is_effects/is_effects.dart'
    show
        Args,
        ExecResult,
        Exited,
        Killed,
        ProposedRequest,
        WebResponse,
        decodeProposedRequest;
import 'package:is_conversation_reply_vocabulary/is_conversation_reply_vocabulary.dart'
    show RepliesInSlackConversation, RepliesUnderWebAddress, ReplyEndpoint;
import 'package:is_model_vocabulary/is_model_vocabulary.dart' show ModelUsage;
import 'package:is_shapes/is_shapes.dart' show TrajectoryId;
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart' show SignIn;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show AddressPrefix, encodeAddressPrefix;

/// The web address a reply to [endpoint] is sent under, or null when the
/// loop can't send to it: a Slack conversation is named in a reply's body,
/// not its address, and no drawing writes one yet.
AddressPrefix? replyAddressFor(ReplyEndpoint endpoint) => switch (endpoint) {
  RepliesUnderWebAddress(:final prefix) => prefix,
  RepliesInSlackConversation() => null,
};

/// The actions of a reply saying [text], such as the model's answer or why
/// its call was refused, to [replyEndpoint] as [signIn]: [drawing] is
/// run on it and prints the requests as one JSON array of is_effects'
/// `encodeProposedRequest`; those are then sent in order. Done with how
/// many were sent; [Failed] when either action is refused, the drawing
/// fails, what it printed is not requests, or the destination refuses one
/// ([sentOrRefused]). [turn], [step] and [usage], how full
/// the model's context is when the call reported it, go to the drawing
/// for the message's footer, and [trajectory] to what its Close closes.
Action<int> replyActions({
  required Executable drawing,
  required String text,
  required ModelUsage? usage,
  required AddressPrefix replyEndpoint,
  required SignIn signIn,
  required TrajectoryId trajectory,
  required int? turn,
  required int step,
}) => drawing.runOrFail(
  drawingArgs(
    text: text,
    usage: usage,
    replyEndpoint: replyEndpoint,
    signIn: signIn,
    trajectory: trajectory,
    turn: turn,
    step: step,
  ),
  then: (ExecResult drawn) => switch (drawn) {
    Exited(exitCode: 0, :final stdout) => switch (requestsIn(stdout)) {
      (requests: final requests?, why: _) => Program.makeWebRequests.runOrFail(
        requests,
        then: sentOrRefused,
      ),
      (requests: null, :final why) => Failed(
        '${drawing.name} printed no requests: $why',
      ),
    },
    Exited(:final exitCode, :final stderr) => Failed(
      '${drawing.name} exited $exitCode: ${stderr.trim()}',
    ),
    Killed(:final why) => Failed('${drawing.name} was killed: $why'),
  },
);

/// Done with how many [responses] there are when the destination took every
/// request (a 2xx status); otherwise [Failed], naming the first it refused,
/// its status and why. The web driver returns a refusal as a response, so
/// the action running is not the reply arriving.
Result<int> sentOrRefused(List<WebResponse> responses) {
  for (final (i, response) in responses.indexed) {
    if (response.status < 200 || response.status > 299) {
      return Failed(
        'request $i was refused with ${response.status}: '
        '${response.refusedBecause ?? 'no reason given'}',
      );
    }
  }
  return Done(responses.length);
}

/// How a drawing is run for [text]: the endpoint, sign-in, trajectory,
/// turn (when known), step and context as flags, and the text on its stdin.
/// Both counts start at 0; the drawing shows them from 1. `--step` is
/// always sent, so a drawing reads `--turn` as the turn, never as the step
/// an older loop sent under that name.
Args drawingArgs({
  required String text,
  required ModelUsage? usage,
  required AddressPrefix replyEndpoint,
  required SignIn signIn,
  required TrajectoryId trajectory,
  required int? turn,
  required int step,
}) => Args([
  '--reply-endpoint',
  jsonEncode(encodeAddressPrefix(replyEndpoint)),
  '--sign-in',
  signIn.name,
  '--trajectory',
  trajectory.hex,
  if (turn != null) ...['--turn', '$turn'],
  '--step',
  '$step',
  if (usage != null) ...['--context-tokens', '${usage.context}'],
  if (usage?.contextWindow case final window?) ...[
    '--context-window',
    '$window',
  ],
], stdin: text);

/// [printed], a drawing's stdout, read as its requests: one JSON array of
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

/// [result] carried on through [proposer] until it is no longer an
/// [Action]: each action a continuation leads to is proposed in turn.
Future<Result<A>> runToEnd<A>(
  Result<A> result,
  ProposesActions proposer,
) async {
  var current = result;
  while (true) {
    switch (current) {
      case Action<A>():
        current = await current.next(proposer);
      case Done<A>() || Failed():
        return current;
    }
  }
}
