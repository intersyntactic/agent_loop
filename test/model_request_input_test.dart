// Proves a model request's turns encode as the JSON array of Responses API
// input items the drivers take: real turns, oldest first, no system item.
import 'dart:convert' show jsonDecode;

import 'package:agent_loop/agent_loop.dart';
import 'package:test/test.dart';

void main() {
  test('UserSaid and ReplyText turns become user and assistant items, '
      'oldest first', () {
    final turns = [
      const TurnEnvelope(
        node: {
          'shape': 'UserSaid',
          'author': 'teams:u1',
          'source': 'm1',
          'text': 'hey are you there',
        },
        provenance: Own(),
      ),
      const TurnEnvelope(
        node: {'shape': 'ReplyText', 'by': 'agent:a1', 'text': 'yep, here'},
        provenance: Own(),
      ),
    ];

    expect(
      jsonDecode(encodeModelInput([for (final t in turns) inputTurnOf(t)])),
      [
        {'role': 'user', 'content': 'hey are you there'},
        {'role': 'assistant', 'content': 'yep, here'},
      ],
    );
  });

  test('throws for a node shape it does not know', () {
    expect(
      () => inputTurnOf(
        const TurnEnvelope(node: {'shape': 'Mystery'}, provenance: Own()),
      ),
      throwsFormatException,
    );
  });
}
