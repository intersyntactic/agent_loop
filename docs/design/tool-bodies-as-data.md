# Tool bodies as data: the model writes Dart, a transpiler turns it into a closed term language, and the agent loop evaluates the terms

Status: proposal, round 2 (21 Nov 2026), after a 4/4 RECAST in
[TEMPER.md](TEMPER.md). For agent_loop, is_tool / is_tools_api (tool-af),
is_airlock_api (airlock-api-b3), documents_module (documents-module-21), the
docx driver (docx-driver-ce) and teams_module (teams-module-aa). Nothing here
is built.

## What Nick asked for

- The agent loop only knows tools. It does the agent loop and writes down
  tool calls; the airlock decides what happens (21 Nov 20:20).
- A tool is like a function: a **signature** (name, parameters, return type,
  description) and a **body**. The signature goes into the tool manifest in
  the system prompt; the body is actions the airlock decides and drivers carry
  out (21:16).
- Each step, pure computation included, could itself be a proposed action
  (21:21). Code should be data (21:25).
- The model may write its own tools and load them at run time when the
  operator allows it; the operator chooses how much power the model gets
  (21:33).
- The model writes **Dart**, which it knows well and can think in, and a
  **transpiler** turns it into the safe language, so what the model writes is
  guaranteed representable in it (22:17).

## What exists today, and why it doesn't fit

is_tool's `ToolHandler` is a Dart closure: `handler.reply(input, crux)` runs
the body in the process that holds it. Each action goes through the airlock,
but everything between actions is compiled code nobody outside can read,
record or check. The loop program would have to include every tool package,
documents would be parsed in the loop, and the model couldn't write a tool.

## The shape

```
model writes Dart ──► transpiler (analyzer front end) ──► terms ──► recorded ──► evaluator in the loop
                       rejects what has no translation             (the body)     pure core runs here;
                       with a Dart-shaped error                                    each action = proposal
```

### A tool is two pieces of data

1. **The signature**: `ToolSpec.toJson()` (name, description, input schema)
   plus a return type. Shown to the model in the manifest.
2. **The body**: a **term program** in the closed language below, with the
   Dart source it came from kept beside it for people to read. What runs is
   the terms, never the Dart.

### The term language is the safety

A small language, specified once, with its own evaluator in agent_loop:

- **Pure forms:** literals, records, local bindings, `if`, `switch` on a
  closed set, field access, and a fixed table of operations on strings,
  integers, booleans and lists (`length`, `substring`, `contains`, `+`, `==`,
  …). Every operation is total and deterministic, and its cost is bounded by
  the size of its inputs.
- **One effect form:** `propose(action, arguments)`, which proposes a declared
  action at the turn's next place and **suspends** until its outcome is in the
  record.
- **No** import form, no host call, no loops, no recursion, no exceptions, no
  clock, no randomness, no environment.

An operation the table lacks **can't be written** in the term language, so
nothing has to reject it. That's the difference from round 1, where two
checkers had to agree on what Dart was banned. The evaluator is small enough
to review whole, and it's the one part that's safety-critical.

The terms are JSON (an S-expression in arrays), so they travel and are
recorded with checked_json like every other entry. No new parser sits at the
trust boundary.

### The transpiler is outside the safety boundary

The model writes ordinary Dart against a library of declared actions and
value types:

```dart
Future<Passage> readDocument(String name) async {
  if (!name.toLowerCase().endsWith('.docx')) {
    return Passage.refusedBecause('$name is not a Word document (.docx)');
  }
  final file = await fetch(graph, drivePath(drive, folder, name));
  return await docxToPassage(file, maxChars: 20000);
}
```

The transpiler resolves it with `analyzer` and translates node by node into
terms. It **guarantees one direction only**: everything it accepts means the
same in the terms as in Dart. Anything without a translation is rejected with
a Dart-shaped error the model can act on, never approximated:

> `line 4: String.padLeft isn't available in tools. Available on String: length, substring, contains, startsWith, endsWith, toLowerCase, split, +`

The rules it enforces by translating, not by checking:

- `await` only on a declared action. A future can't be held as a value, so a
  body's actions run one at a time in source order.
- No `try`/`catch` around an action. A refusal ends the call (see below).
- No `for`, `while` or recursion, at first. A bounded `for` over an outcome's
  list may be added later, if a real tool needs one.
- No import except the action library.

**A transpiler bug can make a tool wrong, never unsafe.** The language it
emits has no unsafe word, so even a wrong translation can't import, reach the
clock, or call outside the action table.

### Values in the core are small; documents stay in drivers

The core holds small scalars, records and **references** to recorded
outcomes, never document-sized data. An action takes references as
arguments, and a driver returns a bounded result. Above, `fetch` returns a
reference to the fetched bytes, and `docxToPassage` (the docx driver) takes
that reference and returns an already-cut passage. A zip bomb or pathological
XML is the driver's problem, inside its confinement, never the core's.

*Open:* the fetched bytes are then an outcome in the logbook. Their size,
retention and privacy need a price, or a driver that parses needs to read the
bytes from the fetching driver without recording them twice. Owner:
airlock-api-b3 with the drivers.

### A refusal ends the call

When the airlock refuses an action, the call ends there, and the model sees
the refusal as the call's error result. A body never receives a refusal as a
value it can branch on, so it can't probe the airlock (which names, sizes or
recipients fail) and adapt without the model seeing.

## Replay: bound by proposal, pinned by version

A restarted loop re-evaluates a call's recorded terms, with the same
arguments, against the record.

- **Each outcome is keyed by the proposal it answers.** That's the proposal's
  digest: the action, its arguments (references included) and the body's
  identity. Re-evaluation derives each proposal again. If the record holds that
  exact proposal, its outcome is used. If the record holds a *different*
  proposal at that place, the call **halts**. It never takes an outcome by
  position.
- **The execution contract is pinned per call:** the body's content hash (of
  its terms), the action library's version and the evaluator's version are
  recorded with the call. A restart on a different evaluator or library
  version halts the call. Because the **terms** are recorded, not the Dart,
  a transpiler upgrade can't change an in-flight call.
- **Tool definitions are immutable within a trajectory.** Redefining a name
  makes a new tool; calls already made stay pinned to the body they ran.

### Duplicate effects across a crash

The proposal entry is durable intent with an identity, written before the
airlock decides. A restarted loop that finds its proposal in the record waits
for that proposal's outcome; it never proposes it again. The remaining window
is the airlock's: it dispatched, then died before recording the outcome. The
contract is one dispatch per proposal id, and a dispatched-but-unrecorded
proposal is an **unknown outcome**: the call halts and is never
automatically re-dispatched. Owner: airlock-api-b3 / airlock-5c.

### Ordering

The text format allows one tool call per model reply, and the reply ends with
it. A body's actions run in source order, one at a time. So a turn's places
are deterministic: model call, then the call's actions in order, then the
next model call.

## What the operator grants

Per action, a tool adds no reach: every effect is a proposal the airlock
decides against the trajectory's rules. **What a tool does grant is
closed-loop composition**: a body can condition later actions on earlier
outcomes (fetch, branch, send) without a model turn and without the airlock
seeing the sequence as a whole, faster than anyone watches. A model-written
body may call any action in the library, not only those behind its given
tools. That is the power, and the operator grants it.

Levels, in the trajectory's starting rules, as a closed set:

0. **Given tools only.** Bodies from modules, reviewed and merged by people.
1. **Model-written tools, for this trajectory.** The model writes Dart in a
   reply; the transpiler accepts or rejects it with errors the model sees; the
   terms are recorded and callable from then on; the tool dies with the
   trajectory.
2. **Open, for Nick:** model-written tools kept for later trajectories.
   Recommendation: **delete it.** A body written under one trajectory's
   purpose and rules would run under another's, and per-tool approval only
   guards that rather than removing it. A tool worth keeping becomes source a
   person merges into a module (level 0). "Load at run time" is served by
   level 1.

A model never adds an **action**. Actions are driver capabilities, added by
people: the line between self-modification and escaping the airlock.

## Where it runs

The evaluator runs in the agent loop's process. The loop holds no sign-ins or
secrets (its own contract), and with no loops, no recursion and bounded
values, evaluation is bounded by body size. So a body can't stall the loop
for long. If the term language ever gains loops, revisit: a confined worker
with only a proposal pipe.

## Stages

1. **Actions as tools, no evaluator.** Heavy computation goes to drivers
   (`docxToPassage`, the Teams card build-and-send), and ids (drive, folder)
   go in the manifest. Today's tools are one action or a fixed short sequence
   the loop runs. This serves CAM now.
2. **The term language, the evaluator and the transpiler**, for level 1.

## First proof (stage 2's gate)

In agent_loop, no deploy. It passes only if each of these **fails closed**,
plus the happy path:

1. The happy path: `readDocument` above transpiles, its terms are recorded,
   and it evaluates against an in-memory crux: suspend at `fetch`, resume,
   suspend at `docxToPassage`, resume, return.
2. Kill after the first action; re-evaluate; only the second action is
   proposed.
3. A replay that derives a **different** second proposal (the body changed
   under it): halts.
4. An evaluator or action-library version mismatch on restart: halts.
5. A refused action: the call ends, and the model sees the refusal.
6. A body using `dart:io`, `DateTime.now`, `String.padLeft`, `try`/`catch`
   around an action, a `for` loop, or recursion: each rejected by the
   transpiler with a Dart-shaped error naming the line.
7. A dispatched-but-unrecorded proposal: the unknown outcome halts the call,
   with no re-dispatch.
8. **Measure** the transpiler's size for this subset. It's a guess (one to
   two thousand lines) until it's measured.

Then one read workflow and one send workflow, across crash boundaries.

## Who does what (once agreed)

- **agent_loop** (this session): the term language spec, the evaluator,
  replay, the transpiler, the manifest in the system prompt.
- **is_tools_api / is_tool** (tool-af): the signature gains a return type;
  the action library's Dart declarations; `ToolHandler` retired.
- **is_airlock_api** (airlock-api-b3): actions taking outcomes by reference;
  the one-dispatch-per-proposal contract and unknown outcomes; reach types for
  pure actions; the level in the rules.
- **docx driver** (docx-driver-ce): `docxToPassage`, bytes in by reference, a
  bounded passage out.
- **documents_module** (documents-module-21): `read_document` and
  `list_documents` as Dart bodies.
- **teams_module** (teams-module-aa): stage 1, the card build-and-send as a
  driver action; stage 2, `reply` as a body.
