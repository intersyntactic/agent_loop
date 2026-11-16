// Pins the exact bytes a ReplyText turn is written as, agreed with
// teams-module-e2 (16 Nov): kind `turn`, node {"shape": "ReplyText", "by",
// "answers", "text"}, inside TurnEnvelope's usual {"node", "provenance"}
// wrapping. teams_reply's renderer reads only `shape` and `text`; `by`
// and `answers` are kept for ReplyText's full shape and are ignored by its
// pattern match, not read by it.
//
// Not yet wired to a real call site (task 11): this proves the bytes
// TurnEnvelope.encode would produce for this node today, which is what a
// renderer parsing them by hand needs pinned, ahead of the streaming
// integration that will actually produce one.
import 'dart:convert';

import 'package:agent_loop/agent_loop.dart';
import 'package:test/test.dart';

void main() {
  test('a ReplyText turn envelope encodes to the agreed bytes', () {
    final envelope = TurnEnvelope(
      node: {
        'shape': 'ReplyText',
        'by': 'agent:abc123',
        'answers': 'a' * 64,
        'text': 'Hello back!',
      },
      provenance: const Own(),
    );

    final decoded = jsonDecode(utf8.decode(envelope.encode()));
    expect(decoded, {
      'node': {
        'shape': 'ReplyText',
        'by': 'agent:abc123',
        'answers': 'a' * 64,
        'text': 'Hello back!',
      },
      'provenance': {'kind': 'own'},
    });

    // teams_reply's own pattern match, reproduced: it reads only shape and
    // text, so by and answers being present alongside them doesn't matter.
    final node = (decoded as Map<String, Object?>)['node'];
    expect(node, isA<Map<String, Object?>>());
    expect((node as Map<String, Object?>)['shape'], 'ReplyText');
    expect(node['text'], isA<String>());
  });
}
