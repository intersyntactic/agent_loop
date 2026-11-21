# Tool bodies as data: a tool is a signature and a body, and the body is code the agent loop interprets

Status: proposal, 21 Nov 2026. For agent_loop, is_tool / is_tools_api
(tool-af), is_airlock_api (airlock-api-b3), documents_module
(documents-module-21), the docx driver (docx-driver-ce) and teams_module
(teams-module-aa). Nothing here is built.

## What Nick asked for

- The agent loop only knows tools. It does the agent loop and writes down
  tool calls; the airlock decides what happens (Nick, 21 Nov 20:20).
- A tool is like a function: a **signature** (name, parameters, return type,
  description) and a **body**. The signature goes into the tool manifest in
  the system prompt, so the model can decide to call it. The body is a set of
  actions that the airlock decides on and the drivers carry out (21:16).
- Each step in a body, including pure computation like turning a docx into
  text, could itself be a proposed action (21:21).
- Code should be data: "what if we used Lisp, where code is data?" (21:25).
- The model may write its own tools and load them at run time, **when the
  operator allows it**. That's appropriate in some contexts and not others.
  Runtime self-modification is one of intersyntactic's goals, and the
  operator chooses how much power the model gets (21:33).

## What exists today, and why it doesn't fit

is_tool's `ToolHandler` is a Dart closure. `handler.reply(input, crux)` runs
the body *inside the process that holds the handler*. Each action in it goes
through the airlock, but everything between the actions (unzipping a docx,
building an Adaptive Card, splitting at 28 KB) is compiled Dart that nobody
outside can see, record or check. A body is code you can only run, never
read. So:

- the loop program would have to include every tool package's code;
- strangers' bytes (a document) would be parsed in the loop's process;
- the model can't write a tool, because a tool is compiled code;
- what happens between two actions is in no record.

## The proposal

### A tool is two pieces of data

1. **The signature**: `ToolSpec.toJson()` as today: name, description, input
   schema, plus the return type. Shown to the model in the manifest.
2. **The body**: source code, stored as text, in a small language (see
   *Which language*). It names its parameters and returns a value of the
   declared type.

Both travel as data: in the trajectory's starting rules for the tools a
trajectory starts with, or in a record entry for one the model writes later
(see *Power levels*).

### The body runs by evaluation, and every effect is a proposal

The agent loop evaluates a body with the call's arguments. It has two kinds
of operation:

- **The pure core** (`if`, `switch`, local variables, records, string and
  number operations, reading a field) is evaluated in the loop. It reaches
  nothing and is deterministic.
- **Actions** (`fetch`, `send`, `docxToText`, `readFile`, …), whose types are
  declared once in a library, are never run by the loop. Calling one
  **proposes it at the turn's next place**. The loop pauses, reads the
  outcome from the logbook, and resumes with it as the call's value. A
  refused action is a value too (`Refused(why)`), which the body can match on
  or let end the call.

For example (Dart, see below):

```dart
Future<Passage> readDocument(String name, {int maxChars = 20000}) async {
  if (!name.toLowerCase().endsWith('.docx')) {
    throw ToolError('$name is not a Word document (.docx)');
  }
  final response = await fetch(graph, drivePath(drive, folder, name), keep: bytes);
  final text = await docxToText(response.body);   // an action: a driver parses
  return Passage.cut(text, maxChars);              // pure core
}
```

`fetch` and `docxToText` are proposals, each decided and recorded. The `if`
and `Passage.cut` run in the loop. The docx itself is unzipped in a driver,
which holds no secrets and is confined, never in the loop.

### Why this is safe to compose: a tool adds no reach

Every effect in a body is an action the airlock decides against the
trajectory's rules. So **a tool, whoever wrote it, can't reach anything the
model couldn't reach by calling the same actions one by one.** A tool is
composition, not capability. That holds for module-written and model-written
tools alike, and it's why letting the model write tools is a question of
judgment and cost, not of breaking the airlock.

What a tool *can* do that the model alone can't is act without the model
seeing each step in between, and act faster. That's the power being granted,
and the operator grants it (see *Power levels*).

### Replay: a restart re-evaluates and resumes

The pure core is deterministic. So a restarted loop evaluates the same body
with the same arguments and reaches the same actions at the same places.
Where the record already holds a place's outcome, the evaluator takes it
instead of proposing again. A call that was half done picks up at its first
unanswered step. This is how durable-execution systems (Temporal's
workflows) work: the workflow is code replayed against a history of events,
and its effects are recorded activities. Here the logbook is that history.

The condition is hard: **nothing in the core may be nondeterministic.** No
clock, no randomness, no iteration order over unordered collections that can
vary between runs, no reading the environment. Anything like that is an
action, so its value is recorded.

## Which language

What matters is that a body can be **recorded** (any text can), **read
before it runs** (parsed and checked), and **run with every effect
intercepted**. JSON isn't required for any of them.

| | Dart subset, interpreted | Lisp (s-expressions) | Lisp as JSON arrays |
|---|---|---|---|
| Model writes it reliably | best: a huge corpus | adequate | poor: models know JSON as data, not code |
| Type checking | the real one (`analyzer`), errors the model reads | we'd write one | we'd write one |
| Evaluator size | large, even for a subset | a few hundred lines | a few hundred lines |
| New parser at the trust boundary | `analyzer` (official, large) | a small reader | none (checked_json) |
| House language (AGENTS.md: everything in Dart) | yes | no | no |

**Recommendation: a Dart subset, interpreted.** The model writes it best,
the official type checker checks it against the declared action signatures
before it runs, and it's the house language. Checking once at the boundary,
with the compiler holding it after, is AGENTS.md's whole stance, and an
untyped body would give that up.

The cost is the interpreter. Two routes:

1. **dart_eval** (pub.dev, 0.8.5, May 2026): "a flexible Dart bytecode
   compiler and interpreter written in Dart, enabling dynamic execution and
   code push for AOT Dart apps". **Unverified:** whether it can suspend at an
   action and resume from a recorded outcome, which replay needs; how much of
   Dart it covers; and whether it can be denied every library except ours.
2. **Our own interpreter over `analyzer`'s resolved AST**, for a deliberately
   small subset: functions, `async`/`await` (only on actions), records,
   `if`/`switch`/patterns, `final` locals, string and int operations, and our
   value types. No classes, no loops at first, no imports.

The first proof should decide between them (see *First proof*).

**Lisp stays the fallback** if the interpreter proves too costly. Its
evaluator and type checker are small. The price is that the model writes it
less well, and its type errors are ours to word.

### The subset is enforced, never trusted

A body may import exactly one library: the declared actions and value types.
`analyzer` rejects anything else before evaluation: other imports, `dart:io`,
`DateTime.now`, `Random`, `Platform`, `Zone`, top-level mutable state, and
any construct outside the subset. The interpreter refuses the same set, so
two checks guard it. A body that escapes the subset could go around the
airlock and would break replay, so this is the safety-critical part.

## Power levels: the operator chooses

Carried in the trajectory's starting rules, as a closed set:

0. **Given tools only.** The manifest holds tools from modules, as reviewed.
   The model calls them. (What every trajectory gets today.)
1. **Model-written tools, this trajectory only.** The model may define a tool
   (signature and body) in a reply. The loop checks it (`analyzer`, the
   subset) and records it, and the model can call it from then on, within
   this trajectory. It reaches nothing new (see above), and it dies with the
   trajectory.
2. **Model-written tools, kept.** As 1, but a tool may be saved for later
   trajectories. That needs an operator's approval per tool, because a tool
   written under one trajectory's rules would run under another's. The
   airlock still decides each action under the new rules, so what's at risk
   is behaviour, not reach.

A model never adds an **action** (a new kind of effect). Actions are driver
capabilities, added by people. That's the line between self-modification and
escaping the airlock.

## What this replaces, and what survives

- **Survives:** the tool-call text format (`<tool_call>{"name","input"}</tool_call>`,
  agent_loop branch `feat/tool-calls-as-text`, 24972ff); `ToolSpec`'s
  signature and `toJson`; `[turn, step]` places (a body's actions are the
  turn's steps); proposals pointing to earlier outcomes by entry id (as
  `ReplyToEvent.reply` already did).
- **Replaced:** `ToolHandler` as a closure; documents_module's Dart handlers
  (their bodies become Dart-subset source, and their parsing becomes the
  docx driver's action); teams_module's card building (a `reply` tool whose
  body builds the card in the core and proposes `send`).
- **New:** the action library (signatures of every action a body may call);
  the evaluator in agent_loop; the docx driver's `docxToText` action; a
  card-building path in teams_module's `reply` tool body; the power level in
  is_flight_rules.

## Risks and open questions

1. **The interpreter is the new attack surface**, and it runs in the loop
   with model-written input at power level 1. Mitigations: the subset,
   checked twice; a step budget per call (instructions and actions); no
   recursion and no loops until a real tool needs one.
2. **Pure computation that's too heavy for the core.** Card building and
   splitting are cheap. Anything heavy (parsing a format, compressing)
   belongs in a driver as an action. Where the line falls is a judgment per
   operation.
3. **Determinism has to be proven, not hoped for.** A test: evaluate every
   body twice against the same recorded outcomes and compare the proposals
   byte for byte.
4. **The model writing Dart that type-checks but means the wrong thing.**
   That's no different from the model calling actions wrongly one at a time,
   and the airlock bounds both.
5. **The cost of a pure step as an action** (a record write and an airlock
   decision per step) is unmeasured. Likely small next to a model call.
6. **What `docxToText` reaches:** nothing in the world, so the airlock
   decides it trivially. It still needs a driver and a reach type of its own,
   so a grant to parse is never a grant to fetch.

## First proof (before anything else is built)

In agent_loop, no deploy:

1. Take `read_document` as above. Write the action library with `fetch` and
   `docxToText` declared.
2. Check the body with `analyzer` against the library. Confirm that a body
   importing `dart:io` or calling `DateTime.now` is rejected.
3. Evaluate it with route 1 (dart_eval), and if it can't suspend and resume,
   route 2 (our interpreter), using an in-memory crux that answers actions
   from a script of outcomes.
4. Kill it after the first action, re-evaluate against the recorded outcome,
   and show it proposes only the second action.

If 1 to 4 hold, the design holds; if 3 needs route 2 and that's large, put
Lisp back on the table.

## Who does what (once agreed)

- **agent_loop** (this session): evaluator, replay, the power level's loop
  side, the manifest in the system prompt.
- **is_tools_api / is_tool** (tool-af): the signature gains a return type;
  the action library's home; `ToolHandler` retired.
- **is_airlock_api** (airlock-api-b3): actions that take earlier outcomes by
  reference; reach types for pure actions; the power level in the rules.
- **docx driver** (docx-driver-ce): `docxToText` as a driver action.
- **documents_module** (documents-module-21): `read_document` and
  `list_documents` as bodies.
- **teams_module** (teams-module-aa): `reply` as a body (escaping, card,
  28 KB split in the core; `send` as the action).
