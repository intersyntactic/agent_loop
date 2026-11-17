// Proves recordModelRequest against a real JournalService: the piece and
// the request land on the chain's own tip in order, and the request's
// join() accepts exactly the body that was recorded, by hash.
import 'dart:convert' show jsonDecode, utf8;
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart' show Ran;
import 'package:is_journal/is_journal.dart';
import 'package:is_journal/service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late JournalService service;
  late JournalWriter writer;
  final kind = Kind.parse('turn')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_model_request_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList(
        '$uid turn model-request-piece model-request\n'.codeUnits,
      ),
    );
    service = await JournalService.start(
      Journal.open(Directory('${tmp.path}/journal'))!,
      senderTable,
      File('${tmp.path}/journal.sock'),
    );
    writer = JournalWriter('${tmp.path}/journal.sock');
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  test('the request names each half\'s piece, and joins back to it', () async {
    final chain = JourneyPathChain(writer: writer, kind: kind);
    final turn = await chain.append({
      'shape': 'Note',
      'text': 'hi',
    }, const Own());

    final requestEntry = await recordModelRequest(
      chain,
      systemPrompt: 'the exact rendered system prompt',
      request: 'the exact rendered request',
      builtFrom: [EntryHash.parse(turn.entry.hex)!],
    );

    expect(chain.tip, requestEntry);

    final entries = File('${tmp.path}/journal/entries').readAsBytesSync();
    final last = JournalEntry.parse(
      entries.sublist(entries.length - JournalEntry.length),
    )!;
    expect(last.previous, isNot(EntryHash.origin));

    final requestObject = service.journal.get(last.object)!;
    final request = ModelRequest.fromJson(
      _decodeJson(_stripHeader(requestObject)),
    );

    String textOf(RecordedText text) {
      final pieceBytes = service.journal.get(
        _findEntryObject(entries, text.pieces.single),
      )!;
      return ModelRequestPiece.fromJson(_decodeJson(_stripHeader(pieceBytes)))
          .text;
    }

    final systemPromptText = textOf(request.systemPrompt);
    final requestText = textOf(request.request);

    expect(systemPromptText, 'the exact rendered system prompt');
    expect(requestText, 'the exact rendered request');
    expect(request.systemPrompt.join([systemPromptText]), isA<Ran<String>>());
    expect(request.request.join([requestText]), isA<Ran<String>>());
    expect(request.builtFrom.single.hex, turn.entry.hex);
  });
}

Object? _decodeJson(Uint8List bytes) => jsonDecode(utf8.decode(bytes));

/// The object hash of the entry whose own hash is [entry], by scanning the
/// entries file: no read socket in this stage.
ObjectId _findEntryObject(Uint8List entries, EntryId entry) {
  for (var at = 0; at < entries.length; at += JournalEntry.length) {
    final raw = Uint8List.sublistView(entries, at, at + JournalEntry.length);
    if (EntryHash.of(raw).hex == entry.hex) {
      return JournalEntry.parse(raw)!.object;
    }
  }
  throw StateError('no entry ${entry.hex}');
}

/// The bytes after an entry object's own `<kind>\n<previous>\n` header.
Uint8List _stripHeader(Uint8List object) {
  final first = object.indexOf(0x0a);
  final second = object.indexOf(0x0a, first + 1);
  return Uint8List.sublistView(object, second + 1);
}
