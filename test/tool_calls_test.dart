// Proves what the model is offered and what it hears back: a tool is shown
// by name, description and schema only; a call names an offered tool or is
// answered that it can't run; and a fetch's outcome maps to a result where
// ToolRefused comes only from NothingRan.
import 'dart:typed_data' show Uint8List;

import 'package:agent_loop/agent_loop.dart';
import 'package:checked_json/checked_json.dart' show JsonObject;
import 'package:is_effects/is_effects.dart'
    show
        BytesBody,
        NothingRan,
        Outcome,
        Ran,
        StoppedPartway,
        TextBody,
        WebResponse;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show CalledToolName, ToolCall, ToolCallId, ToolInput;
import 'package:is_sign_in_vocabulary/is_sign_in_vocabulary.dart' show SignIn;
import 'package:is_web_address_vocabulary/is_web_address_vocabulary.dart'
    show Origin, WebPath;
import 'package:is_model_vocabulary/is_model_vocabulary.dart'
    show ToolFailed, ToolName, ToolRan, ToolRefused, ToolResult;
import 'package:is_tools_api/is_tools_api.dart'
    show Fetch, Input, OneActionTool;
import 'package:test/test.dart';

final _fetch = Fetch(
  Origin.parse('https://graph.microsoft.com')!,
  WebPath.parse('/v1.0/drives/b!xyz/items/01F/children')!,
  SignIn.parse('enspyr-test')!,
);

final _listDocuments = ToolName.of('list_documents');

OneActionTool _tool(String name, {Input<Object?>? input}) => OneActionTool.of(
  name: ToolName.of(name),
  description: 'Lists the channel folder.',
  input: input ?? Input.none,
  action: _fetch,
);

ToolCall _call(String name, {String input = '{}'}) => ToolCall(
  id: ToolCallId.parse('toolu_1')!,
  name: CalledToolName.fromSent(name),
  input: ToolInput.parse(input)!,
);

void main() {
  group('offeredTools', () {
    test('shows a tool by its name, description and input schema', () {
      final [offered] = offeredTools([_tool('list_documents')]);

      expect(offered.name.value, 'list_documents');
      expect(offered.description, 'Lists the channel folder.');
      expect(
        offered.inputSchema.asUncheckedMap(),
        Input.none.schema.asUncheckedMap(),
      );
    });
  });

  group('toolCalled', () {
    final tools = {_listDocuments: _tool('list_documents')};

    test('a call naming a given tool runs it', () {
      expect(
        toolCalled(_call('list_documents'), tools),
        isA<CallRuns>().having((c) => c.tool, 'tool', same(tools.values.first)),
      );
    });

    test('a name never offered, well formed or not, fails: nothing ran, but '
        'nothing was refused', () {
      for (final name in ['read_documents', 'functions.list_documents']) {
        expect(
          toolCalled(_call(name), tools),
          isA<CallCannotRun>().having(
            (c) => c.result.text,
            'text',
            contains(name),
          ),
        );
      }
    });

    test("input the tool can't read fails, naming the tool", () {
      final strict = {
        _listDocuments: _tool(
          'list_documents',
          input: Input.parse(
            JsonObject.of({
              'type': 'object',
              'properties': {
                'folder': {'type': 'string'},
              },
              'required': ['folder'],
              'additionalProperties': false,
            }),
          )!,
        ),
      };

      expect(
        toolCalled(_call('list_documents'), strict),
        isA<CallCannotRun>().having(
          (c) => c.result.text,
          'text',
          startsWith("list_documents's input"),
        ),
      );
    });
  });

  group('fetchResult', () {
    final outcomes = <String, (Outcome<WebResponse>?, Matcher)>{
      'nothing ran': (
        const NothingRan('the airlock denied it'),
        isA<ToolRefused>().having((r) => r.why, 'why', 'the airlock denied it'),
      ),
      'stopped partway': (
        const StoppedPartway<WebResponse>(why: 'the socket closed', done: null),
        isA<ToolFailed>().having(
          (r) => r.text,
          'text',
          contains("don't retry"),
        ),
      ),
      'a 2xx with text': (
        const Ran(WebResponse(status: 200, body: TextBody('3 files'))),
        isA<ToolRan>().having((r) => r.text, 'text', '3 files'),
      ),
      'a non-2xx': (
        const Ran(WebResponse(status: 403, refusedBecause: 'accessDenied')),
        isA<ToolFailed>().having(
          (r) => r.text,
          'text',
          'the site answered 403: accessDenied',
        ),
      ),
      'a 2xx with no text': (
        Ran(WebResponse(status: 200, body: BytesBody(Uint8List(2)))),
        isA<ToolFailed>(),
      ),
      'an outcome that does not read': (null, isA<ToolFailed>()),
    };

    for (final MapEntry(key: what, value: (outcome, heard))
        in outcomes.entries) {
      test('$what: ${heard.describe(StringDescription())}', () {
        expect(fetchResult(outcome), heard);
      });
    }

    test('ToolRefused comes only from NothingRan', () {
      for (final MapEntry(key: what, value: (outcome, _)) in outcomes.entries) {
        final ToolResult heard = fetchResult(outcome);
        expect(
          heard is ToolRefused,
          outcome is NothingRan,
          reason:
              '$what: the model must never hear "refused" when '
              'something ran',
        );
      }
    });
  });
}
