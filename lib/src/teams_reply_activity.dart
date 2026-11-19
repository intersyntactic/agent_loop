/// The Teams message a reply goes out as, built by the airlock's own
/// projection rather than here: the airlock rebuilds the body from the
/// recorded outcome and refuses a request whose bytes differ, so the loop
/// asks that same projection for them instead of copying its rules (such
/// as the line a cut-off reply ends with).
library;

import 'dart:convert' show jsonEncode;

import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_airlock_api/is_airlock_api.dart'
    show Projection, outcomeOfProposedActionToJson;
import 'package:is_effects/is_effects.dart'
    show ModelReply, Ran, encodeModelReply, encodeOutcome;
import 'package:is_shapes/is_shapes.dart' show EntryId;

/// [reply], which the model gave in answer to [proposed], as the Teams
/// activity [Projection.teamsMessageFromModelReply] draws from its
/// outcome. Null if the projection draws nothing from it.
Map<String, Object?>? teamsReplyActivity(ModelReply reply, EntryId proposed) {
  final recorded = jsonEncode(
    outcomeOfProposedActionToJson(
      proposed,
      encodeOutcome(Ran(reply), encodeModelReply),
    ),
  );
  final body = Projection.teamsMessageFromModelReply.drawnFrom(recorded);
  if (body == null) return null;
  return JsonObject.decode(body).asUncheckedMap();
}
