// Proves TurnEnvelope and TurnProvenance round-trip through encode/decode:
// both are pure, so no journal or logbook service is needed to prove it.
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_journal/is_journal.dart' show EntryHash;
import 'package:test/test.dart';

void main() {
  test('an envelope with Own provenance round-trips its node', () {
    const envelope = TurnEnvelope(
      node: {'shape': 'Note', 'text': 'c'},
      provenance: Own(),
    );

    final decoded = TurnEnvelope.decode(envelope.encode());

    expect(decoded.node, {'shape': 'Note', 'text': 'c'});
    expect(decoded.provenance, isA<Own>());
  });

  test('an envelope with FromAdmission provenance round-trips its admitted '
      'hash', () {
    final admitted = EntryHash.of(Uint8List.fromList('admitted'.codeUnits));
    final envelope = TurnEnvelope(
      node: const {'shape': 'Note', 'text': 'c'},
      provenance: FromAdmission(admitted),
    );

    final decoded = TurnEnvelope.decode(envelope.encode());

    expect(decoded.provenance, isA<FromAdmission>());
    expect((decoded.provenance as FromAdmission).admitted, admitted);
  });
}
