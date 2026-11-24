// Proves a reply is the drawing's run, then exactly the requests it
// printed, each at its own place in the turn's reply, and that a drawing
// that fails or prints nothing usable sends nothing.
import 'dart:convert';

import 'package:agent_loop/agent_loop.dart';
import 'package:is_airlock_api/is_airlock_api.dart'
    show
        ActionProposedByAgentLoop,
        Crux,
        Done,
        Executable,
        Failed,
        ProposedForTheReply,
        ProposesActionsThroughTheLogbook,
        outcomeOfProposedActionToJson;
import 'package:is_effects/is_effects.dart'
    show
        AddressPrefix,
        ExecResult,
        Exited,
        ModelUsage,
        Origin,
        PathPrefix,
        ProgramName,
        Ran,
        NothingRan,
        SignIn,
        WebResponse,
        encodeExecResult,
        encodeOutcome,
        encodeWebResponse;
import 'package:is_docking_station_api/is_docking_station_api.dart'
    show
        RepliesInSlackConversation,
        RepliesUnderWebAddress,
        SlackChannelId,
        SlackMessageTimestamp;
import 'package:is_shapes/is_shapes.dart' show EntryId, TrajectoryId;
import 'package:test/test.dart';

final _endpoint = AddressPrefix.of(
  Origin.parse('https://smba.trafficmanager.net')!,
  PathPrefix.parse('/amer/v3/conversations/c1/')!,
);
final _signIn = SignIn.parse('cam-teams')!;
final _trajectory = TrajectoryId.parse('a1' * 32)!;
final _drawing = Executable(ProgramName.parse('teams-reply-drawing')!);

const _request = {
  'origin': 'https://smba.trafficmanager.net',
  'method': 'post',
  'path': '/amer/v3/conversations/c1/activities',
  'signIn': 'cam-teams',
  'headers': {'content-type': 'application/json'},
  'body': '{"type":"message","text":"hi"}',
};

/// Writes each proposal it is handed, and answers it with the next of
/// [outcomes], given the proposal's id.
final class _FakeLink implements ProposesActionsThroughTheLogbook {
  _FakeLink(this.outcomes);

  final List<Object? Function(EntryId proposed)> outcomes;
  final proposals = <ActionProposedByAgentLoop>[];

  @override
  Future<EntryId> writeProposal(String body) async {
    switch (ActionProposedByAgentLoop.read(body)) {
      case final ActionProposedByAgentLoop proposal:
        proposals.add(proposal);
      case final other:
        throw StateError('not a proposal: $other');
    }
    return EntryId.of(utf8.encode('proposal ${proposals.length}'));
  }

  @override
  Future<String> outcomeNaming(EntryId proposed) async => jsonEncode(
    outcomeOfProposedActionToJson(
      proposed,
      outcomes[proposals.length - 1](proposed),
    ),
  );
}

Object? _drawn(ExecResult result) =>
    encodeOutcome(Ran(result), encodeExecResult);

Object? _sent(int count) => encodeOutcome(
  Ran([for (var i = 0; i < count; i++) const WebResponse(status: 201)]),
  (List<WebResponse> rs) => [for (final r in rs) encodeWebResponse(r)],
);

void main() {
  group('drawingArgs', () {
    test('text goes on stdin, with the turn and context for its footer', () {
      final args = drawingArgs(
        text: 'hello',
        usage: const ModelUsage(
          input: 100,
          cacheRead: 50,
          output: 7,
          contextWindow: 200000,
        ),
        replyEndpoint: _endpoint,
        signIn: _signIn,
        trajectory: _trajectory,
        turn: 3,
      );

      expect(args.stdin, 'hello');
      expect(args.args, [
        '--reply-endpoint',
        jsonEncode({
          'origin': 'https://smba.trafficmanager.net',
          'pathPrefix': '/amer/v3/conversations/c1/',
        }),
        '--sign-in',
        'cam-teams',
        '--trajectory',
        'a1' * 32,
        '--turn',
        '3',
        '--context-tokens',
        '150',
        '--context-window',
        '200000',
      ]);
    });

    test('no usage, no context flags', () {
      final args = drawingArgs(
        text: 'hello',
        usage: null,
        replyEndpoint: _endpoint,
        signIn: _signIn,
        trajectory: _trajectory,
        turn: 1,
      );

      expect(args.args, isNot(contains('--context-tokens')));
      expect(args.args, isNot(contains('--context-window')));
    });
  });

  group('requestsIn', () {
    test('reads a JSON array of proposed requests', () {
      final read = requestsIn(jsonEncode([_request, _request]));

      expect(read.requests, hasLength(2));
      expect(read.requests!.first.path.value, _request['path']);
    });

    test('an empty array, or not JSON, is no requests', () {
      expect(requestsIn('[]').requests, isNull);
      expect(requestsIn('not json').requests, isNull);
      expect(requestsIn('{}').requests, isNull);
    });

    test('a request claiming a grant is no requests', () {
      final read = requestsIn(
        jsonEncode([
          {..._request, 'grantedPathPrefix': '/'},
        ]),
      );

      expect(read.requests, isNull);
      expect(read.why, contains('grantedPathPrefix'));
    });
  });

  group('replyActions', () {
    test('runs the drawing, then sends what it printed, at reply places 0 '
        'and 1', () async {
      final printed = jsonEncode([_request]);
      final link = _FakeLink([
        (_) => _drawn(Exited(0, stdout: printed, stderr: '')),
        (_) => _sent(1),
      ]);

      final result = await runToEnd(
        replyActions(
          drawing: _drawing,
          text: 'hi',
          usage: null,
          replyEndpoint: _endpoint,
          signIn: _signIn,
          trajectory: _trajectory,
          turn: 4,
        ),
        Crux.forTheReply(link, turn: 4),
      );

      expect(result, isA<Done<int>>().having((d) => d.value, 'sent', 1));
      expect(
        [for (final p in link.proposals) p.place],
        [ProposedForTheReply.at(4, 0), ProposedForTheReply.at(4, 1)],
      );
      expect(link.proposals.first.program, _drawing);
    });

    test('a drawing that exits nonzero sends nothing', () async {
      final link = _FakeLink([
        (_) => _drawn(const Exited(65, stdout: '', stderr: 'nothing to say')),
      ]);

      final result = await runToEnd(
        replyActions(
          drawing: _drawing,
          text: ' ',
          usage: null,
          replyEndpoint: _endpoint,
          signIn: _signIn,
          trajectory: _trajectory,
          turn: 1,
        ),
        Crux.forTheReply(link, turn: 1),
      );

      expect(
        result,
        isA<Failed>().having((f) => f.why, 'why', contains('exited 65')),
      );
      expect(link.proposals, hasLength(1));
    });

    test('a refused send is the reply failing', () async {
      final link = _FakeLink([
        (_) => _drawn(Exited(0, stdout: jsonEncode([_request]), stderr: '')),
        (_) => encodeOutcome<Object?>(
          const NothingRan('not under a reply grant'),
          (_) => null,
        ),
      ]);

      final result = await runToEnd(
        replyActions(
          drawing: _drawing,
          text: 'hi',
          usage: null,
          replyEndpoint: _endpoint,
          signIn: _signIn,
          trajectory: _trajectory,
          turn: 2,
        ),
        Crux.forTheReply(link, turn: 2),
      );

      expect(
        result,
        isA<Failed>().having((f) => f.why, 'why', contains('reply grant')),
      );
    });
  });

  group('replyAddressFor', () {
    test('a reply under a web address goes under its prefix', () {
      expect(replyAddressFor(RepliesUnderWebAddress(_endpoint)), _endpoint);
    });

    test('a Slack conversation gets no address, so no reply is sent', () {
      final slack = RepliesInSlackConversation(
        origin: Origin.parse('https://slack.com')!,
        channel: SlackChannelId.parse('C0123ABC')!,
        thread: SlackMessageTimestamp.parse('1700000000.000100'),
      );
      expect(replyAddressFor(slack), isNull);
    });
  });
}
