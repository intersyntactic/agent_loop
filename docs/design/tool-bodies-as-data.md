# Tool bodies as data: the model writes JSON terms, and the agent loop evaluates them

Status: proposal, round 3 (21 Nov 2026), after RECAST 4/4 in rounds 1 and 2
([TEMPER.md](TEMPER.md)). For agent_loop, is_tool / is_tools_api (tool-af),
is_airlock_api (airlock-api-b3), the airlock (airlock-5c), documents_module
(documents-module-21), the docx driver (docx-driver-ce) and teams_module
(teams-module-aa). Nothing here is built. The language gets its name through
a crucible once the design settles.

## What Nick asked for

- The agent loop only knows tools; it writes down tool calls and the airlock
  decides what happens (21 Nov 20:20).
- A tool is a function: a **signature** (name, parameters, return type,
  description) in the manifest, and a **body** of actions the airlock decides
  and drivers carry out (21:16). Every step can be a proposed action (21:21).
  Code is data (21:25).
- The model may write its own tools and load them at run time when the
  operator allows it (21:33).
- Tools are functions and models know tools as JSON in and JSON out, so the
  body is JSON too (23:07). The model writes the terms directly: no Dart, no
  transpiler (decided 23:10, after round 2 found the transpiler to be an
  unreviewed semantic authority).
- Level 2, model-written tools kept across trajectories, is deleted (23:10).

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
model writes terms ──► checked (JSON, forms, ops, sizes) ──► recorded ──► evaluated in the loop
                                                              (the body)    pure core here;
                                                                            each action = a proposal
```

One artifact: what the model writes is what's recorded, reviewed and run.

### A tool definition is one JSON object

```json
{"name": "read_document",
 "description": "Reads a Word document from the reports folder.",
 "input_schema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
 "bound": {"drive": "b!xyz", "folder": "01abc"},
 "body": ["fn", ["name", "drive", "folder"], …]}
```

`bound` holds values fixed when the tool is defined, such as the drive and
folder ids. They're recorded with the tool, so the model never types them,
and a reviewer sees exactly what the tool reaches. The body's parameters are
the call's input plus the bound names; nothing else is in scope.

### The term language

- **Values:** strings, integers, booleans, records, lists, and opaque
  **references** to recorded outcomes (what `fetch` returns).
- **Forms:** `fn`, `let`, `if`, `fail`, `propose`, `record`, `list`, and
  `[<op>, …]` for a fixed table of pure operations, each with a fixed
  argument order (the table in the experiment: `concat`, `lower`, `endsWith`,
  `substring`, `filterSuffix`, `maxBy`, `toText`, …).
- **No** import form, host call, loop, recursion (a body never calls a body),
  exception other than `fail`, clock, randomness or environment. Something
  outside the table can't be written, so nothing has to reject it.
- **Every operation is total:** `substring` clamps, `at` out of range halts
  the call, `maxBy` of an empty list halts it. Nothing throws.
- **Sizes are bounded at construction:** each string at most 64 KiB, each
  list at most 1,000 elements, integers within ±2^53, a body at most 64 KiB
  of JSON. An operation whose result would exceed a bound halts the call. So
  `s = concat(s, s)` repeated can't run away, and cost is bounded by body size
  times the bounds.

The evaluator and its operation table are the safety-critical part, small
enough to review whole. The experiment's throwaway evaluator was about 250
lines of Dart.

### Effects, refusals, halts

- `propose(action, args…)` proposes a declared action at the call's next
  ordinal and suspends until its outcome is in the record.
- **Outcomes are success-only.** A driver can't return "not found" as a value
  a body switches on. Every denial goes through the airlock's refusal, which
  **ends the call**, and the model sees it as the call's error result. So a
  body can't probe the airlock and adapt unseen.
- **Halt** (an operation out of bounds, a replay mismatch, an unknown
  outcome) also ends the call with an error result the model sees, naming why.
  The turn continues; a halt never wedges a trajectory.

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
is empty or only whitespace sends nothing. The model never
supplies the address: the reply tool's destination comes from the
trajectory's start entry, and the airlock's path-prefix rule for the starting
conversation is the boundary. If the reply itself is refused, the turn ends
under the per-turn cap on tool calls and repeated refusals; the record shows
why.

## Replay

A restarted loop re-evaluates a call's recorded body with its recorded
arguments.

- **Identity is the occurrence: (call instance, ordinal).** The proposal is
  stored at its ordinal. Re-evaluation derives each proposal again and
  requires it to **equal** the stored one; a mismatch halts the call. There's
  no lookup by content, so two identical `send`s in one body are two
  occurrences, and both dispatch.
- **Pinned per call:** the body's hash, the operation table's version and the
  action library's version. A restart on different versions halts the call
  (an error result the model sees, not a stuck turn).
- **Tool names are immutable within a trajectory.** Redefining makes a new
  tool, and calls already made keep their body.

### The airlock's dispatch states

Owner: airlock-api-b3 / airlock-5c. A proposal is **proposed** (in the
record) → **dispatched** (recorded durably *before* the effect) → **recorded**
(the outcome). Drivers treat (call instance, ordinal) as an idempotency key,
and a retry reuses it. A proposal found dispatched but unrecorded is an
**unknown outcome**: the call halts, and it is never automatically
re-dispatched.

## What the operator grants

Per action, a tool adds no reach: the airlock decides every effect against
the trajectory's rules. **What a tool grants is closed-loop composition:** a
body can condition later actions on earlier outcomes (fetch, branch, send)
without a model turn, and without the airlock seeing the sequence as a whole.
A model-written body may call any action in the library, not only those
behind its given tools.

Levels, in the trajectory's starting rules, as a closed set:

0. **Given tools only.** Bodies from modules, reviewed and merged by people.
1. **Model-written tools, for this trajectory.** The model writes a
   definition in a reply; the loop checks it (JSON, forms, operations,
   sizes) and records it; the model can call it from then on; it dies with
   the trajectory.

There is no level 2. A tool worth keeping becomes a module's tool that a
person merges (level 0). Keeping model-written tools would let one
trajectory's injected behaviour fire in another, and that is removed, not
guarded.

A model never adds an **action**; actions are driver capabilities, added by
people. That's the line between self-modification and escaping the airlock.

## Where it runs

In the agent loop's process. The loop holds no sign-ins or secrets, and with
total, size-bounded operations and no loops or recursion, a body's cost is
bounded. Checking a definition is JSON parsing plus a walk over the terms;
no compiler or analyzer runs on model-written input.

## Stages

1. **Actions as tools, composed by the model.** The actions themselves are
   the tools (`fetch`, `docxToPassage`, `send`), one action per tool call,
   with `bound` ids shown in the manifest. No evaluator, no loop-side
   sequences. This serves CAM now.
2. **The term language and the evaluator**, for level 1. Module tools
   (level 0) move to bodies at the same time. Gate: a first level-1 workflow,
   chosen with Nick, that needs composition.

The tool-call text format, `<tool_call>{"name", "input"}</tool_call>`
(agent_loop branch `feat/tool-calls-as-text`), serves both stages. In stage 2
a model-written definition arrives through a `define_tool` call.

## First proof (stage 2's gate)

In agent_loop, no deploy. It passes only if each of these behaves as stated:

1. Happy path: `read_document` and a `send` workflow evaluate against an
   in-memory crux, suspending and resuming at each action.
2. Kill after the first action; re-evaluate; only the second is proposed.
3. Two identical `send`s in one body: two occurrences, both dispatch; a
   crash between them resumes at the second.
4. A second call with the same arguments never receives the first call's
   outcome.
5. A re-derived proposal that differs from the stored one: halts.
6. A version mismatch on restart: halts, with an error result the model sees.
7. `concat(s, s)` repeated past the string bound: halts, and the loop stays
   responsive.
8. A driver result over its bound is never a core value; no fetched bytes in
   the record.
9. A refusal ends the call, and the model sees it.
10. A dispatched-but-unrecorded proposal: unknown, no re-dispatch; a retry
    reuses the occurrence id.
11. A malformed definition (bad JSON, an unknown form or operation, a wrong
    argument count, a free variable, oversize): rejected with an error naming
    the place.

## Who does what (once agreed)

- **agent_loop** (this session): the term language spec, checker and
  evaluator; replay by occurrence; the `define_tool` path; the manifest.
- **is_tools_api / is_tool** (tool-af): a definition with `bound` and `body`;
  `ToolHandler` retired.
- **is_airlock_api / airlock** (airlock-api-b3, airlock-5c): dispatch states,
  idempotency by occurrence, unknown outcomes, success-only outcomes,
  references between drivers, the level in the rules.
- **docx driver** (docx-driver-ce): `docxToPassage`, bytes in by reference, a
  bounded passage out.
- **documents_module** (documents-module-21): `read_document` and
  `list_documents` as bodies, `DriveFolder` ids as `bound`.
- **teams_module** (teams-module-aa): stage 1, the card build-and-send as a
  driver action; stage 2, `reply` as a body.
