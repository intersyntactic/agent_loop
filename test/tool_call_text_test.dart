// Proves how a model's text reply is read as an answer or a tool call, and
// that every call the model can't be held to comes back as a reason it is
// told, never as a guess.
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:agent_loop/agent_loop.dart';
import 'package:is_tools_api/is_tools_api.dart';
import 'package:test/test.dart';

String _why(ReadModelReply read) => switch (read) {
  ToolCallUnreadable(:final why) => why,
  AnswerText() || CallsTool() => fail('expected unreadable, got $read'),
};

void main() {
  test('a reply with no call is the answer, as it is', () {
    final read = readModelReply('  Here it is.\n');
    expect(read, isA<AnswerText>());
    expect((read as AnswerText).text, '  Here it is.\n');
  });

  test('a call at the end of a reply names its tool and input', () {
    final read = readModelReply(
      'Let me look.\n<tool_call>\n'
      '{"name": "read_document", "input": {"name": "Q3.docx"}}\n'
      '</tool_call>\n',
    );
    switch (read) {
      case CallsTool(:final name, :final input):
        expect(name, 'read_document');
        expect(input.string('name'), 'Q3.docx');
      case AnswerText() || ToolCallUnreadable():
        fail('expected a call, got $read');
    }
  });

  test('a call with no input takes an empty one', () {
    final read = readModelReply('<tool_call>{"name": "list"}</tool_call>');
    expect((read as CallsTool).input.keys, isEmpty);
  });

  test('a call that is cut off, doubled or followed by text is unreadable', () {
    expect(
      _why(readModelReply('<tool_call>{"name": "a"}')),
      contains('no </tool_call>'),
    );
    expect(
      _why(
        readModelReply(
          '<tool_call>{"name": "a"}</tool_call>'
          '<tool_call>{"name": "b"}</tool_call>',
        ),
      ),
      contains('one call'),
    );
    expect(
      _why(readModelReply('<tool_call>{"name": "a"}</tool_call> Done.')),
      contains('text after it'),
    );
  });

  test('a call that is not the agreed JSON says which part is wrong', () {
    expect(
      _why(readModelReply('<tool_call>read it</tool_call>')),
      contains('not a JSON object'),
    );
    expect(
      _why(readModelReply('<tool_call>{"input": {}}</tool_call>')),
      contains('"name"'),
    );
    expect(
      _why(readModelReply('<tool_call>{"name": "a", "input": 3}</tool_call>')),
      contains('"input"'),
    );
    expect(
      _why(readModelReply('<tool_call>{"name": "a", "args": {}}</tool_call>')),
      contains('"args"'),
    );
  });

  test('the prompt shows each tool as its Messages-shape definition', () {
    final spec = ToolSpec<String, String>(
      name: 'echo',
      description: 'Says it back.',
      input: Input.field(Field('text', Schema.string())),
      output: Output.text,
    );
    final prompt = toolsPrompt([spec]);
    expect(prompt, contains('<tool_call>'));
    final line = prompt.split('\n').last;
    expect(jsonDecode(line), {
      'name': 'echo',
      'description': 'Says it back.',
      'input_schema': jsonDecode(jsonEncode(spec.inputSchema)),
    });
    expect(toolsPrompt(const []), isEmpty);
  });

  test('a result is marked an error only when it is one', () {
    expect(
      toolResultText('3 files', isError: false),
      '<tool_result>\n3 files\n</tool_result>',
    );
    expect(
      toolResultText('no such file', isError: true),
      startsWith('<tool_result error>\n'),
    );
  });
}
