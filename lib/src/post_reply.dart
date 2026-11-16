/// Asks the airlock, in its own process, to carry out a post — one
/// [Post], already built, sent as a [Carry] over an [AirlockLink]
/// (RULINGS, "No server": the loop and the airlock are separate services,
/// so what passes between them is a message with a type).
///
/// Building the [Post] itself — filling in its path and headers — is not
/// here, on purpose: that's still an open design question (Nick), so it
/// stays its own function, to change without touching how a post is
/// carried out once built.
library;

import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart' show Outcome, Sent;

/// Carries out [post] as the journey path [journeyPath]'s apex at
/// [place], over [link], showing [token] as that path's loop.
///
/// The one way this package asks the airlock for anything: a tool never
/// calls this directly, since [Program.web.run] is the contract a tool's
/// own code describes a post through; this is what a tool's `next(apex)`
/// does when the apex is [Apex.through].
Future<Outcome<Sent>> postReply({
  required AirlockLink link,
  required JourneyPathId journeyPath,
  required PathToken token,
  required Object? place,
  required Post post,
}) async {
  final apex = Apex.through(
    link,
    journeyPath: journeyPath,
    token: token,
    place: place,
  );
  final result = await Program.web
      .run<Outcome<Sent>>(post, then: Done.new)
      .next(apex);
  return switch (result) {
    Done(value: final outcome) => outcome,
    // `then` above only ever wraps the outcome in Done, so neither case
    // below is reachable; the switch must still cover Result's other cases.
    Failed(:final why) => throw StateError('unreachable: $why'),
    Run() => throw StateError('unreachable: next() gave a Run'),
  };
}
