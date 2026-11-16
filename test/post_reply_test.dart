// Proves postReply against a fake AirlockLink: no real transport exists yet
// (RULINGS, "No server" — the airlock is its own process, reached over a
// link this package does not implement), so this proves the wire shape and
// the decode, not a real socket.
import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart';
import 'package:is_effects/is_effects.dart';
import 'package:test/test.dart';

void main() {
  final journeyPath = JourneyPathId.of(
    Uint8List.fromList(utf8.encode('a journey path')),
  );
  final token = PathToken.parse('a' * 64)!;
  final origin = Origin.parse('https://smba.trafficmanager.net')!;
  final renderer = RendererName.parse('teams-reply')!;
  final entry = EntryId.of(Uint8List.fromList(utf8.encode('a chunk')));

  test('sends a Carry naming the journey path, token, place and post, '
      'and decodes a Ran outcome', () async {
    final link = _FakeAirlockLink({
      'kind': 'ran',
      'output': {'status': 201, 'created': 'abc', 'refusedBecause': null},
    });

    final outcome = await postReply(
      link: link,
      journeyPath: journeyPath,
      token: token,
      place: 'turn-1',
      post: Post(origin, renderer: renderer, entries: [entry]),
    );

    expect(outcome, isA<Ran<Sent>>());
    expect((outcome as Ran<Sent>).output.status, 201);
    expect(outcome.output.created, 'abc');

    expect(link.received, {
      'journeyPath': journeyPath.hex,
      'token': token.hex,
      'place': 'turn-1',
      'program': 'web',
      'input': {
        'origin': 'https://smba.trafficmanager.net',
        'method': 'post',
        'path': '',
        'signIn': null,
        'headers': <String, String>{},
        'renderer': 'teams-reply',
        'entries': [entry.hex],
      },
    });
  });

  test('decodes a Refused outcome', () async {
    final link = _FakeAirlockLink({
      'kind': 'refused',
      'why': 'no renderer named teams-reply',
    });

    final outcome = await postReply(
      link: link,
      journeyPath: journeyPath,
      token: token,
      place: 'turn-1',
      post: Post(origin, renderer: renderer, entries: [entry]),
    );

    expect(outcome, isA<Refused>());
    expect((outcome as Refused).why, 'no renderer named teams-reply');
  });
}

final class _FakeAirlockLink implements AirlockLink {
  _FakeAirlockLink(this._answer);

  final Object? _answer;
  Object? received;

  @override
  Future<Object?> carry(Object? request) async {
    received = request;
    return _answer;
  }
}
