// Proves the Teams post a reply goes out as carries exactly the bytes the
// airlock's projection draws from the reply's outcome: the airlock refuses
// any other, so a finished reply and a cut-off one must both match.
import 'dart:convert' show jsonEncode;

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart'
    show Projection, outcomeOfProposedActionToJson;
import 'package:is_effects/is_effects.dart'
    show
        CutOffReply,
        FinishedReply,
        ModelReply,
        Ran,
        SignIn,
        encodeModelReply,
        encodeOutcome;
import 'package:is_shapes/is_shapes.dart' show EntryId;
import 'package:is_teams_module/is_teams_module.dart'
    show TeamsPost, teamsPostRequest;
import 'package:test/test.dart';

void main() {
  final proposed = EntryId.parse('ab' * 32)!;

  String? postBody(ModelReply reply) {
    final activity = teamsReplyActivity(reply, proposed);
    if (activity == null) return null;
    return teamsPostRequest(
      TeamsPost(
        serviceUrl: Uri.parse('https://smba.trafficmanager.net/au/'),
        conversation: '19:c1@thread.v2',
        activity: activity,
      ),
      SignIn.parse('cam-teams')!,
    ).body;
  }

  String? projected(ModelReply reply) =>
      Projection.teamsMessageFromModelReply.drawnFrom(
        jsonEncode(
          outcomeOfProposedActionToJson(
            proposed,
            encodeOutcome(Ran(reply), encodeModelReply),
          ),
        ),
      );

  test('a finished reply posts exactly the projection\'s bytes', () {
    const reply = FinishedReply(text: 'hi');

    expect(postBody(reply), projected(reply));
    expect(postBody(reply), '{"type":"message","text":"hi"}');
  });

  test('a cut-off reply posts exactly the projection\'s bytes, marked as '
      'cut off', () {
    const reply = CutOffReply(text: 'half a');

    expect(postBody(reply), projected(reply));
    expect(postBody(reply), contains('cut off'));
  });
}
