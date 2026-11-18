// Proves renderRequestBody flattens turns in order into one plain-text body.
import 'package:agent_loop/agent_loop.dart';
import 'package:test/test.dart';

void main() {
  test('flattens UserSaid/ReplyText turns into one plain-text body, oldest '
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
      renderRequestBody(turns),
      'User: hey are you there\nAgent: yep, here',
    );
  });

  test('throws for a node shape it does not know how to render', () {
    expect(
      () => renderRequestBody([
        const TurnEnvelope(node: {'shape': 'Mystery'}, provenance: Own()),
      ]),
      throwsFormatException,
    );
  });
}
