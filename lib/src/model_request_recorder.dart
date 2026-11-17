/// Records what a model call sends, before it is sent (RULINGS: "What a
/// step sends is in the airlock's record"; a model call as an action,
/// https://github.com/enspyrco/intersyntactic/pull/1168). The exact
/// rendered system prompt and request each go in as [ModelRequestPiece]
/// entries, then a [ModelRequest] names each as a [RecordedText] (its
/// pieces, in order, and its sha256) and the turns they were rendered from.
/// The airlock joins each text's pieces, checks the join against its
/// sha256, and hands the model driver exactly those bytes.
library;

import 'dart:convert' show jsonEncode, utf8;

import 'package:is_airlock_api/is_airlock_api.dart'
    show ModelRequest, ModelRequestPiece, RecordedText;
import 'package:is_content_id/is_content_id.dart' show ObjectId;
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:is_journal/service.dart' show Kind;
import 'package:is_shapes/is_shapes.dart' show EntryId;

import 'journey_path_chain.dart';

final _pieceKind = Kind.parse(ModelRequestPiece.kind)!;
final _requestKind = Kind.parse(ModelRequest.kind)!;

/// Records [systemPrompt] and [request] on [chain] as a model request: one
/// [ModelRequestPiece] entry per text (neither is split yet — nothing
/// rendered here is too long for one entry), then a [ModelRequest] entry
/// naming each as a [RecordedText] and [builtFrom], the turns they were
/// rendered from. All land on [chain]'s own tip, in order. Returns the
/// request entry's hash.
Future<EntryHash> recordModelRequest(
  JourneyPathChain chain, {
  required String systemPrompt,
  required String request,
  required List<EntryHash> builtFrom,
}) async {
  final recordedSystemPrompt = await _recordText(chain, systemPrompt);
  final recordedRequest = await _recordText(chain, request);
  final modelRequest = ModelRequest(
    systemPrompt: recordedSystemPrompt,
    request: recordedRequest,
    builtFrom: [for (final turn in builtFrom) EntryId.parse(turn.hex)!],
  );
  final requestBytes = utf8.encode(jsonEncode(modelRequest.toJson()));
  return chain.appendEntry(_requestKind, requestBytes);
}

/// Appends [text] as one [ModelRequestPiece] entry and returns it as a
/// [RecordedText] naming that entry and the text's own sha256.
Future<RecordedText> _recordText(JourneyPathChain chain, String text) async {
  final pieceBytes = utf8.encode(jsonEncode(ModelRequestPiece(text).toJson()));
  final pieceEntry = await chain.appendEntry(_pieceKind, pieceBytes);
  return RecordedText(
    pieces: [EntryId.parse(pieceEntry.hex)!],
    sha256: ObjectId.of(utf8.encode(text)),
  );
}
