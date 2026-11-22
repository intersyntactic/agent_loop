# Tools as data: a tool's steps travel as JSON terms, and the agent loop carries them out

Status: proposal, round 4 (22 Nov 2026), after RECAST 4/4 in rounds 1, 2
and 3 ([TEMPER.md](TEMPER.md)); round 3's ten findings are folded in. For
agent_loop, is_tool / is_tools_api (tool-af), is_airlock_api
(airlock-api-b3), the airlock (airlock-5c), documents_module
(documents-module-21), the docx driver (docx-driver-ce) and teams_module
(teams-module-aa). Nothing here is built. The language gets its name through
a crucible once the design settles.

## The point

A tool's steps are data. So a module **sends its tools over the wire**, and
the agent loop carries them out without ever linking the module's code. A
new module, or a new tool in one, needs no release of the loop. And because
every effect in the steps is a proposal, nothing a tool does is hidden from
the airlock.

## Vocabulary

Mission → Trajectory → Turn → Intent → the tool's **Steps** → Action ⇄ Outcome

- An **intent** is one tool call in the model's reply.
- A tool's **steps** are what it does when called: values worked out in the
  loop, and proposals.
- An **action** is one proposal, which the airlock decides; each has exactly
  one **outcome**.
- A **place** is an address, not a level: **(turn, intent, action)**, "the
  first action of the second intent in turn 3". See [Replay](#replay).

## What Nick asked for

- The agent loop only knows tools; it writes down tool calls and the airlock
  decides what happens (21 Nov 20:20).
- A tool is a function: a **signature** (name, parameters, return type,
  description) in the manifest, and the actions the airlock decides and
  drivers carry out (21:16). Every step can be a proposed action (21:21).
  Code is data (21:25).
- The model may write its own tools and load them at run time when the
  operator allows it (21:33).
- Tools are functions and models know tools as JSON in and JSON out, so the
  steps are JSON too (23:07). The model writes the terms directly: no Dart,
  no transpiler (decided 23:10, after round 2 found the transpiler to be an
  unreviewed semantic authority).
- Level 2, model-written tools kept across trajectories, is deleted (23:10).
- The point is that modules send tools over the wire as data; the word is
  **steps**, not "body", which pointed at code that executes (22 Nov).

## Evidence: the model writes terms reliably

Two experiments (21 Nov), fresh agents given only the spec and the tasks,
every answer **executed** against fake actions and checked on both its result
and its exact sequence of actions. Controls: deliberately broken answers fail
(negative), and a reference solution passes (positive).

1. Five small tools in JSON terms, Lisp text and Starlark, two writers each:
   **30/30** first try in every language. Ceiling: it can't rank them.
2. Five harder tools (nested branches, several effects in a fixed order,
   ints to text, a fix-from-the-checker's-error task), three writers each, in
   positional terms vs calls in tool-call shape (`{"name", "input"}`):
   - positional: **15/15** first try, about 4.5 KB for the five;
   - tool-call shape: 14/15 first try (one missing `]` deep in a chain of
     `let`s), 15/15 after one repair, about 7.0 KB;
   - the repair task: 6/6 writers fixed both planted bugs.

So: **positional terms.** They're as reliable or better, and about a third
smaller. The tool-call shape's extra nesting is where its one error came
from. With samples this small, the honest claim is "no evidence the model
struggles", not "proven".

## The shape

```
module or model sends terms ──► checked (JSON, forms, ops, types, sizes) ──► recorded ──► carried out in the loop
                                                                            (the steps)    pure values here;
                                                                                           each action = a proposal
```

One artifact: what is sent is what's recorded, reviewed and run.

### A tool definition is one JSON object

```json
{"name": "read_document",
 "description": "Reads a Word document from the reports folder.",
 "input_schema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
 "bound": {"drive": "b!xyz", "folder": "01abc"},
 "steps": ["fn", ["name"],
   ["if", ["not", ["endsWith", ["lower", "$name"], ".docx"]],
     ["fail", ["concat", "$name", " is not a .docx"]],
     ["let", ["file", ["propose", "fetch", "graph",
                ["concat", "/drives/", ["bound", "drive"], "/items/", ["bound", "folder"],
                           ":/", "$name", ":/content"]]],
       ["get", ["propose", "docxToPassage", "$file", 5000], "text"]]]]}
```

`bound` holds values fixed when the tool is defined, such as the drive and
folder ids. They're recorded with the tool, so the model never types them,
and a reviewer sees exactly what the tool reaches. **Only a level-0 tool has
`bound`**, set by the person who wrote it; a level-1 definition has no
`bound` field to write (see [What the operator grants](#what-the-operator-grants)).

The `fn` parameters are the call's input only. Bound values live in their
own namespace, read with `["bound", "drive"]` (a literal name, checked
against `bound` at definition), so an input can never shadow one. The bound
values are part of what's hashed and pinned for each call.

### The two kinds of tool

- A **level-0 tool's steps** propose actions: `["propose", "<action>", …]`.
- A **level-1 tool's steps** call the trajectory's given tools, `["call",
  "<tool>", …]`, each with its own bound values, and never name an action.

Nothing else calls a level-1 tool: only the model does. So calls go at most
two deep (the model calls a level-1 tool, which calls given tools, which
propose actions), and recursion can't be written.

### The term language

- **Values:** strings, integers, booleans, records, lists, and opaque
  **references** to recorded outcomes (what `fetch` returns).
- **Forms:** `fn`, `let`, `if`, `fail`, `bound`, `record`, `list`, `propose`
  (level 0 only), `call` (level 1 only), and `[<op>, …]` for a fixed table of
  pure operations, each with a fixed argument order (the table in the
  experiment: `concat`, `lower`, `endsWith`, `prefix`, `substring`, `get`,
  `filterSuffix`, `maxBy`, `toText`, …). A string starting with `$` is a
  variable; any other string is literal text.
- **Records:** `["record", "title", <term>, "count", <term>]` takes
  alternating literal keys and terms. Keys are non-empty, unique and written
  out, never computed, so a record's shape is known at definition. `["get",
  <record>, "title"]` reads one; its key must be a literal, checked against
  the shape.
- **No** import form, host call, loop, recursion, exception other than
  `fail`, clock, randomness or environment. Something outside the table
  can't be written, so nothing has to reject it.
- **No operation throws.** Each returns a value or halts the call:
  `substring` out of range halts, and `prefix(s, n)` is the one that clamps
  ("the first n characters"); `at` out of range and `maxBy` of an empty list
  halt. Nothing truncates silently.
- **Checked at definition:** JSON, known forms and operations, argument
  counts, no free variables, and every argument's type against the
  signature of the operation, action or tool it's passed to. Values have no
  polymorphism beyond a list's element type, so the checker infers each
  term's type in one walk.
- **Sizes are bounded at construction:** each string at most 64 KiB; each
  list at most 1,000 elements; each value at most 256 KiB serialized and 16
  deep, counting shared parts every time they appear; integers within
  ±2^53; a tool's steps at most 64 KiB of JSON. Per call: at most 4 MiB
  allocated in total and at most 10,000 terms evaluated. Exceeding any of
  these halts the call. So `s = concat(s, s)` repeated, or a list of lists of
  a shared string, can't run away.

### The operation table is defined once

Each operation is one entry in a table, as data: its name, its parameters'
names and types, one sentence of meaning, and the Dart that runs it. The
model's spec text, the parameter labels in the review rendering and the
checker's signatures are all **generated from that table**, so what the
model is told an operation does can't drift from what it does. The table and
the evaluator are the safety-critical part, small enough to review whole.
The experiment's throwaway evaluator was about 250 lines of Dart.

### Effects, refusals, halts

- `propose(action, args…)` proposes a declared action at the intent's next
  action number and suspends until its outcome is in the record. A given
  tool called from a level-1 tool proposes under the same intent,
  continuing its action numbers.
- **Steps can't branch on a refusal or a failure.** An airlock refusal or a
  driver failure **ends the call**, and the model sees it as the call's
  error result. So a tool can't probe the airlock and adapt unseen. What
  this does *not* claim: a successful outcome carries information, by
  design, and steps branch on it. A question like "does this file exist,
  else create it" is a list followed by a read, never a read that fails.
- **A lost acknowledgement isn't a failure.** If an effect was dispatched
  and its outcome never came back, the outcome is unknown (see
  [dispatch states](#the-airlocks-dispatch-states)).
- **Halt** (an operation out of bounds, a replay mismatch, an unknown
  outcome) also ends the call with an error result the model sees, naming why.
  The turn continues; a halt never wedges a trajectory.
- **A call that ends early lists what already happened.** Its error result
  names each action that completed and its outcome ("`send`, action 0:
  done"), so a model that retries knows what not to redo. A retry is a new
  intent, at a new place; the record doesn't stop it re-sending. That
  residue is the same as a model calling `send` twice by hand, and the
  airlock's rules are its bound. Accepted by Nick.

### Review

A person reviews a level-0 tool in a **canonical rendering**, never the raw
positional JSON: one `propose` per line, with each argument labelled by its
name from the action's signature. The rendering is generated from the
recorded steps, so what is reviewed is what runs.

### Documents stay in drivers

`fetch` returns a **reference**, and the bytes stay with the fetching driver.
The logbook records the proposal and a hash, not the bytes. `docxToPassage`
(the docx driver) reads the bytes by reference and returns an
already-bounded passage. A stranger's document is parsed only in a confined
driver, never in the core, and never copied into the record. Owner of the
cross-driver read: airlock-api-b3 with the drivers.

## Replying

A turn's final plain text **is** the reply (Nick, 21 Nov 23:29). The loop
hands it to the conversation's reply tool, so the model calls tools only to
act, never to speak, and a turn always reaches the person. Final text that
is empty or only whitespace sends nothing. The model never supplies the
address: the reply tool's destination comes from the trajectory's start
entry, and the airlock's path-prefix rule for the starting conversation is
the boundary. If the reply itself is refused, the turn ends under the
per-turn cap on tool calls and repeated refusals; the record shows why.

## Replay

A restarted loop carries out a call's recorded steps again with its recorded
arguments.

- **Identity is the place: (turn, intent, action).** The intent's number is
  fixed once the model's reply is recorded, which happens before its steps
  propose anything, so a restart recovers it unchanged. Each proposal is
  stored at its place. Carrying the steps out again derives each proposal
  again and requires it to **equal** the stored one; a mismatch halts the
  call. There's no lookup by content, so two identical `send`s in one tool
  are two places, and both dispatch.
- **One numbering, not two.** Today's `PlaceInTrajectory` is (turn, step),
  where `step` counts proposals in a turn. It becomes (turn, intent,
  action), owned by airlock-api-b3, so the logbook and the tool's steps
  share one address. Open: where the loop's own proposals in a turn (the
  model call, the reply from final text) sit, since no intent draws them.
- **Pinned per call:** the hash of the steps (bound values included), the
  operation table's version and the action library's version. A restart on
  different versions halts the call (an error result the model sees, not a
  stuck turn).
- **Tool names are immutable within a trajectory.** Redefining makes a new
  tool, and calls already made keep their steps.

### The airlock's dispatch states

Owner: airlock-api-b3 / airlock-5c. A proposal is **proposed** (in the
record) → **dispatched** (recorded durably *before* the effect) → **recorded**
(the outcome). Drivers treat the place as an idempotency key, and a retry
reuses it. A proposal found dispatched but unrecorded is an **unknown
outcome**. Where the destination honours the idempotency key, the airlock
re-dispatches it under the same key; where it can't, the call halts and the
outcome stays unknown. Which destinations honour the key is
airlock-api-b3's call, recorded per driver.

## What the operator grants

Per action, a tool adds no reach: the airlock decides every effect against
the trajectory's rules. **What a tool grants is closed-loop composition:** its
steps can condition later actions on earlier outcomes (fetch, branch, send)
without a model turn, and without the airlock seeing the sequence as a whole.

A model-written tool calls only the trajectory's **given tools**, each with
the bound values a person set, and never a raw action. So composition adds
no reach at the tool level either: anything a level-1 tool does, the model
could do by calling the given tools one by one. Level 1 saves turns; it
doesn't open doors.

Levels, in the trajectory's starting rules, as a closed set:

0. **Given tools only.** Tools sent by modules, reviewed and merged by
   people. The `define_tool` tool isn't mounted, so a definition can't even
   be sent.
1. **Model-written tools, for this trajectory.** The model sends a
   definition through `define_tool`; the loop checks it (JSON, forms,
   operations, types, sizes; no `bound`; `call` only to given tools) and
   records it; the model can call it from then on; it dies with the
   trajectory.

There is no level 2. A tool worth keeping becomes a module's tool that a
person merges (level 0). Keeping model-written tools would let one
trajectory's injected behaviour fire in another, and that is removed, not
guarded.

A model never adds an **action**; actions are driver capabilities, added by
people. That's the line between self-modification and escaping the airlock.

## Where it runs

In the agent loop's process. The loop holds no sign-ins or secrets, and with
total, size-bounded operations and no loops or recursion, a call's cost is
bounded. Checking a definition is JSON parsing plus a walk over the terms;
no compiler or analyzer runs on what a module or model sends. (Not Dart
loaded at run time, by hot reload or otherwise: Dart can reach `dart:io`,
needs the compiler in production, holds one version per process, and can
read the clock, so it would undo every property above.)

## Stages

1. **One action per tool.** Each tool's steps are a single `propose` of a
   driver action that does its whole job: the docx driver's `readDocument`
   fetches and reads in one action and returns a bounded passage;
   teams_module's card build-and-send is one action. It's the same wire
   format as stage 2; the checker accepts only that one shape, and carrying
   it out is filling in the arguments and proposing. No reference ever
   reaches the model, so none can be forged or forwarded. This serves CAM
   now, and a module written against it keeps working in stage 2.
2. **The term language and the evaluator**, for level 1 and for level-0
   tools of more than one action. Gate: a first workflow, chosen with Nick,
   that needs composition.

The tool-call text format, `<tool_call>{"name", "input"}</tool_call>`
(agent_loop branch `feat/tool-calls-as-text`), serves both stages. In stage 2
a model-written definition arrives through a `define_tool` call.

## First proof (stage 2's gate)

In agent_loop, no deploy. It passes only if each of these behaves as stated:

1. Happy path: `read_document` and a `send` workflow are carried out against
   an in-memory crux, suspending and resuming at each action.
2. Kill after the first action; carry out again; only the second is proposed.
3. Two identical `send`s in one tool: two places, both dispatch; a crash
   between them resumes at the second.
4. A second call with the same arguments never receives the first call's
   outcome.
5. A re-derived proposal that differs from the stored one: halts.
6. A version mismatch on restart: halts, with an error result the model sees.
7. `concat(s, s)` repeated past the string bound: halts, and the loop stays
   responsive.
8. A driver result over its bound is never a core value; no fetched bytes in
   the record.
9. A refusal ends the call, and the model sees it.
10. A dispatched-but-unrecorded proposal: re-dispatched under the same place
    to a destination that honours it; halts as unknown for one that doesn't.
11. A malformed definition (bad JSON, an unknown form or operation, a wrong
    argument count, a wrong argument type, a free variable, a computed
    record key, oversize): rejected with an error naming the place in the
    terms.
12. A level-1 definition that names an action, carries `bound`, or calls a
    level-1 tool: rejected. An input named like a bound value reads the
    input; `["bound", …]` still reads the bound value.
13. At level 0, `define_tool` isn't in the manifest.
14. A call that halts after one `send`: its error result lists the `send`,
    action 0, as done.
15. A value past the depth cap, a call past the allocation cap, a call past
    the cap on terms evaluated: each halts, and the loop stays responsive.
16. `substring` out of range halts; `prefix` past the end returns the whole
    string.
17. The model's spec text, the review labels and the checker's signatures
    are generated from the one operation table.

## Who does what (once agreed)

- **agent_loop** (this session): the term language spec, the operation
  table, checker and evaluator; replay by place; the `define_tool` path; the
  manifest; the canonical rendering for review.
- **is_tools_api / is_tool** (tool-af): a definition with `bound` and
  `steps`, sent over the wire by modules; `ToolHandler` retired.
- **is_airlock_api / airlock** (airlock-api-b3, airlock-5c): the place as
  (turn, intent, action); dispatch states, idempotency by place, unknown
  outcomes and which destinations may re-dispatch, refusals and failures
  ending the call, references between drivers, the level in the rules.
- **docx driver** (docx-driver-ce): `readDocument` for stage 1;
  `docxToPassage`, bytes in by reference and a bounded passage out, for
  stage 2.
- **documents_module** (documents-module-21): `read_document` and
  `list_documents` as tools sent with their steps, `DriveFolder` ids as
  `bound`.
- **teams_module** (teams-module-aa): stage 1, the card build-and-send as a
  driver action; stage 2, `reply` as a tool with steps.
