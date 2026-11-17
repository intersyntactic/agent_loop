/// Records what a model call sends, before it is sent (RULINGS: "What a
/// step sends is in the airlock's record"; a model call as an action,
/// https://github.com/enspyrco/intersyntactic/pull/1168). The exact
/// rendered body goes in as [ModelRequestPiece] entries, then a
/// [ModelRequest] names them in order, the body's sha256, and the turns it
/// was rendered from. The airlock joins the pieces, checks the join against
/// that hash, and hands the model driver exactly those bytes.
library;

import 'dart:convert' show jsonEncode, utf8;

import 'package:is_airlock_api/is_airlock_api.dart'
    show ModelRequest, ModelRequestPiece;
import 'package:is_content_id/is_content_id.dart' show ObjectId;
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;
import 'package:is_shapes/is_shapes.dart' show EntryId;

import 'journey_path_chain.dart';

final _pieceKind = Kind.parse(ModelRequestPiece.kind)!;
final _requestKind = Kind.parse(ModelRequest.kind)!;

/// Records [body] on [chain] as a model request: one [ModelRequestPiece]
/// entry holding the whole body (not yet split — nothing rendered here is
/// too long for one entry), then a [ModelRequest] entry naming it, the
/// body's sha256, and [builtFrom], the turns it was rendered from. Both
/// land on [chain]'s own tip, in order. Returns the request entry's hash.
Future<EntryHash> recordModelRequest(
  JourneyPathChain chain, {
  required String body,
  required List<EntryHash> builtFrom,
}) async {
  final pieceBytes = utf8.encode(jsonEncode(ModelRequestPiece(body).toJson()));
  final pieceEntry = await chain.appendEntry(_pieceKind, pieceBytes);
  final request = ModelRequest(
    pieces: [EntryId.parse(pieceEntry.hex)!],
    body: ObjectId.of(utf8.encode(body)),
    builtFrom: [for (final turn in builtFrom) EntryId.parse(turn.hex)!],
  );
  final requestBytes = utf8.encode(jsonEncode(request.toJson()));
  return chain.appendEntry(_requestKind, requestBytes);
}
