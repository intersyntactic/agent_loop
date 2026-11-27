/// Records what a model call sends, before it is sent, on a
/// [TrajectoryChain] (the live logbook): one [ModelRequestPiece]
/// entry per text, then a [ModelRequestFromPieces] entry naming each as a
/// [TextFromPieces] and the history entries it was built from.
library;

import 'dart:convert' show jsonEncode, utf8;

import 'package:is_airlock_api/is_airlock_api.dart'
    show ModelRequestFromPieces, ModelRequestPiece, TextFromPieces;
import 'package:is_content_id/is_content_id.dart' show ObjectId;
import 'package:is_logbook_client/is_logbook_client.dart'
    as logbook_client
    show ObjectId;
import 'package:is_shapes/is_shapes.dart' show EntryId;

import 'kind_the_loop_writes.dart';
import 'trajectory_chain.dart';

/// Records [systemPrompt] and [request] on [chain] as a model request: one
/// [ModelRequestPiece] entry per text, then a [ModelRequestFromPieces] entry naming
/// each as a [TextFromPieces] and [builtFrom], the history entries they
/// were rendered from. All land on [chain]'s own tip, in order. Returns the request
/// entry's id.
Future<logbook_client.ObjectId> recordModelRequestOnTrajectory(
  TrajectoryChain chain, {
  required String systemPrompt,
  required String request,
  required List<logbook_client.ObjectId> builtFrom,
}) async {
  final recordedSystemPrompt = await _recordText(chain, systemPrompt);
  final recordedRequest = await _recordText(chain, request);
  final modelRequest = ModelRequestFromPieces(
    systemPrompt: recordedSystemPrompt,
    request: recordedRequest,
    builtFrom: [for (final entry in builtFrom) EntryId.parse(entry.hex)!],
  );
  final requestBytes = utf8.encode(jsonEncode(modelRequest.toJson()));
  return chain.appendEntry(KindTheLoopWrites.modelRequest, requestBytes);
}

/// Appends [text] as one [ModelRequestPiece] entry and returns it as a
/// [TextFromPieces] naming that entry and the text's own sha256.
Future<TextFromPieces> _recordText(TrajectoryChain chain, String text) async {
  final pieceBytes = utf8.encode(jsonEncode(ModelRequestPiece(text).toJson()));
  final pieceEntry = await chain.appendEntry(
    KindTheLoopWrites.modelRequestPiece,
    pieceBytes,
  );
  return TextFromPieces(
    pieces: [EntryId.parse(pieceEntry.hex)!],
    sha256: ObjectId.of(utf8.encode(text)),
  );
}
