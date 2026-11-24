// Proves a turn the loop wrote on its own chain becomes the model turn
// every driver reads: a user's or the agent's, oldest first.
import 'package:agent_loop/agent_loop.dart';
import 'package:is_model_vocabulary/is_model_vocabulary.dart' show ModelRequest;
import 'package:test/test.dart';

void main() {
  test('UserSaid and ReplyText turns become user and agent turns, oldest '
      'first', () {
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
      ModelRequest(
        tools: const [],
        turns: [for (final t in turns) inputTurnOf(t)],
      ).encode(),
      '{"tools":[],"turns":['
      '{"kind":"user","text":"hey are you there"},'
      '{"kind":"agent","text":"yep, here"}]}',
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
