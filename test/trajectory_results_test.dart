// Proves followResults against a real LogbookService: an
// outcome-of-proposed-action entry decodes into its ReturnedResult, and a
// body of some other shape under the same kind is skipped rather than
// thrown.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_logbook/is_logbook.dart';
import 'package:is_logbook/service.dart';
import 'package:is_logbook_client/is_logbook_client.dart' as client;
import 'package:is_shapes/is_shapes.dart' show EntryId;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late LogbookService service;
  late client.LogbookWriter writer;
  late client.LogbookReader reader;
  final resultKind = Kind.parse('outcome-of-proposed-action')!;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('agent_loop_results_test_');
    final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
    final senderTable = SenderTable.parse(
      Uint8List.fromList('$uid outcome-of-proposed-action\n'.codeUnits),
    );
    service = await LogbookService.start(
      Logbook.open(Directory('${tmp.path}/logbook'))!,
      senderTable,
      File('${tmp.path}/logbook.sock'),
      readSocket: File('${tmp.path}/logbook.read.sock'),
    );
    writer = client.LogbookWriter('${tmp.path}/logbook.sock');
    reader = client.LogbookReader('${tmp.path}/logbook.read.sock');
  });

  tearDown(() async {
    await service.close();
    tmp.deleteSync(recursive: true);
  });

  test('decodes a result entry, and skips one of another shape', () async {
    final proposed = EntryId.of(Uint8List.fromList('proposal'.codeUnits));

    await writer.write(
      resultKind,
      utf8.encode(jsonEncode({'not': 'a result'})),
    );
    await writer.write(
      resultKind,
      utf8.encode(
        jsonEncode({
          'proposed': proposed.hex,
          'result': {'kind': 'ran', 'output': 'ok'},
        }),
      ),
    );

    final found = <ReturnedResult>[];
    final sub = followResults(reader).listen(found.add);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sub.cancel();

    expect(found, hasLength(1));
    expect(found.single.proposed, proposed);
    expect(found.single.result, {'kind': 'ran', 'output': 'ok'});
  });
}
