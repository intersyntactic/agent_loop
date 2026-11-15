// Proves JournalReader against a real JournalService's read socket, over
// a real Unix socket, not a reimplementation of its wire protocol.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_journal/is_journal.dart';
import 'package:is_journal/service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late JournalService service;
  late JournalWriter writer;
  late JournalReader reader;
  final kind = Kind.parse('turn')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_reader_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList('$uid turn\n'.codeUnits),
    );
    service = await JournalService.start(
      Journal.open(Directory('${tmp.path}/journal'))!,
      senderTable,
      File('${tmp.path}/journal.sock'),
      readSocket: File('${tmp.path}/journal.read.sock'),
    );
    writer = JournalWriter('${tmp.path}/journal.sock');
    reader = JournalReader('${tmp.path}/journal.read.sock');
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  test('follows a kind from the start, then as entries come', () async {
    final a = await writer.append(
      kind,
      null,
      Uint8List.fromList('a'.codeUnits),
    );
    final frames = StreamIterator(reader.follow(kinds: {kind}));

    expect(await frames.moveNext(), isTrue);
    final first = frames.current as JournalEntryFrame;
    expect(first.hash, a);
    expect(first.kind, kind);
    expect(first.follows, isNull);
    expect(String.fromCharCodes(first.body), 'a');

    // The backlog (just `a`) ends here, before anything live.
    expect(await frames.moveNext(), isTrue);
    expect((frames.current as CaughtUp).head, a);

    final b = await writer.append(kind, a, Uint8List.fromList('b'.codeUnits));
    expect(await frames.moveNext(), isTrue);
    final second = frames.current as JournalEntryFrame;
    expect(second.hash, b);
    expect(second.follows, a);
    expect(String.fromCharCodes(second.body), 'b');

    await frames.cancel();
  });

  test('starts after the entry it is given', () async {
    final a = await writer.append(
      kind,
      null,
      Uint8List.fromList('a'.codeUnits),
    );
    final b = await writer.append(kind, a, Uint8List.fromList('b'.codeUnits));
    final frames = StreamIterator(reader.follow(kinds: {kind}, after: a));

    expect(await frames.moveNext(), isTrue);
    expect((frames.current as JournalEntryFrame).hash, b);
    await frames.cancel();
  });

  test('answers a chain tip', () async {
    final a = await writer.append(
      kind,
      null,
      Uint8List.fromList('a'.codeUnits),
    );
    final b = await writer.append(kind, a, Uint8List.fromList('b'.codeUnits));
    expect(await reader.tipOf(a), b);
  });

  test('refuses an unknown tip request', () async {
    final unknown = ObjectId.of(Uint8List.fromList('nothing'.codeUnits));
    final notAChain = EntryHash.parse(unknown.hex)!;
    expect(() => reader.tipOf(notAChain), throwsA(isA<JournalReadRefused>()));
  });

  test('refuses an unknown starting point for follow', () async {
    final unknown = ObjectId.of(Uint8List.fromList('nothing'.codeUnits));
    final notAnEntry = EntryHash.parse(unknown.hex)!;
    final frames = reader.follow(kinds: {kind}, after: notAnEntry);
    await expectLater(frames, emitsError(isA<JournalReadRefused>()));
  });

  test('ends the stream on a bad header, rather than losing every frame '
      'after it', () async {
    final socketFile = File('${tmp.path}/bad_header.sock');
    final server = await ServerSocket.bind(
      InternetAddress(socketFile.path, type: InternetAddressType.unix),
      0,
    );
    final sub = server.listen((client) {
      client.listen((_) {
        client.add(utf8.encode('entry not-a-real-header\n'));
      });
    });
    addTearDown(() async {
      await sub.cancel();
      await server.close();
    });

    final badReader = JournalReader(socketFile.path);
    final frames = badReader.follow();
    await expectLater(
      frames,
      emitsInOrder([emitsError(isA<JournalReadRefused>()), emitsDone]),
    );
  });
}
