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
- A tool's **steps** are what it does when called, of two kinds. An
  **effect step** is a `propose`, which becomes an action. A **computation
  step** works out a value on the way to one (`concat`, `if`, `get`). Only
  effect steps reach the airlock.
- **The loop computes, but has no effects.** It carries out computation
  steps itself, as it already parses replies and builds prompts; anything
  that touches the world is an effect step. A computation step has nothing
  for the airlock to decide, and replay works it out again identically.
- **The model decides between intents, never inside one.** Every decision
  inside a tool (an `if`) was made in advance by whoever wrote the steps,
  like a standing order.
- Only a tool's **result** reaches the model, or, if the call ends early,
  an error listing the actions already done. Values along the way stay in
  the loop and the logbook.
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
- "The loop only knows tools" means **no effects in the loop**, not no
  computation (22 Nov).
- A purely functional language for computation (22 Nov).

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
                                                                            (the steps)    computation steps here;
                                                                                           each action = a proposal
```

One artifact: what is sent is what's recorded, reviewed and run.

### A tool definition is one JSON object

```json
{"name": "read_document",
 "description": "Reads a Word document from the reports folder.",
 "input_schema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
 "bound": {"drive": "b!xyz", "folder": "01abc"},
 "steps":
   ["if", ["not", ["endsWith", ["lower", ["input", "name"]], ".docx"]],
     ["fail", ["concat", ["input", "name"], " is not a .docx"]],
     ["let", ["file", ["propose", "fetch", "graph",
                ["concat", "/drives/", ["bound", "drive"], "/items/", ["bound", "folder"],
                           ":/", ["input", "name"], ":/content"]]],
       ["get", ["propose", "docxToPassage", ["var", "file"], 5000], "text"]]]}
```

(Action names in examples, such as `fetch`, `docxToPassage` and `send`, stand
for an is_airlock_api program on an input; `send` is a `make-web-requests`.)

`bound` holds values fixed when the tool is defined, such as the drive and
folder ids. They're recorded with the tool, so the model never types them,
and a reviewer sees exactly what the tool reaches. **Only a level-0 tool has
`bound`**, set by the person who wrote it; a level-1 definition has no
`bound` field to write (see [What the operator grants](#what-the-operator-grants)).

**Every reference is a form, and every string is literal text.** There are
three namespaces, each read by its own form with a literal name:
`["input", "name"]` (checked against `input_schema`'s properties),
`["bound", "drive"]` (checked against `bound`) and `["var", "file"]` (a
`let` in scope). So inputs, bound values and local names can't shadow each
other, there's no parameter list to disagree with `input_schema`, and a
literal like `"$budget.docx"` means exactly that. (The experiment used
`fn` parameter lists and `$`-prefixed variables; the forms are untested
with models, so the next experiment measures them.) The bound values are
part of what's hashed and pinned for each call.

**Input is checked against `input_schema` when a call comes in.**
is_tools_api's `Input.parse(schema)` rebuilds the same checker a module
built in Dart from the schema it sent, so the schema and its checker are
one description read back, never two.

No output schema: a tool's return type is its action's declared outcome
(stage 1) or derived from the outcomes of the actions and tools it uses
(stage 2). Where the model is shown a return type, it's rendered from those.
No `concurrent` flag either: the airlock decides every effect.

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
- **Forms:** `input`, `bound`, `var`, `let`, `if`, `fail`, `record`, `list`,
  `propose` (level 0 only), `call` (level 1 only), and `[<op>, …]` for a
  fixed table of pure operations, each with a fixed argument order (the
  table in the experiment: `concat`, `lower`, `endsWith`, `prefix`,
  `substring`, `get`, `filterSuffix`, `maxBy`, `toText`, …). A tool's steps
  are one term; there's no `fn` wrapper, since `input_schema` already names
  the inputs.
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
  ±2^53; a tool's steps at most 64 KiB of JSON and **64 terms deep**,
  rejected at definition (without the depth cap, 64 KiB of `[[[[…` nests
  about 32,000 deep and could run a recursive checker out of stack). Per
  call: at most 4 MiB allocated in total and at most 10,000 terms
  evaluated. Exceeding any of these halts the call. So `s = concat(s, s)`
  repeated, or a list of lists of a shared string, can't run away.
- **Against the experiment's 25 tools** (written by models, 22 Nov
  measurement): at most 1,470 bytes (median 657), 15 terms deep (median
  10), 149 terms (median 71) and 6 proposals (median 3). A replayed call
  with 6 proposals evaluates at most about 900 terms. Every cap has at least
  4× headroom over what real tools used.

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
  action number; `next` returns there until its outcome is in the logbook
  (see [A tool's steps are a pure function](#a-tools-steps-are-a-pure-function)). A given
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
  names each action that ran and its outcome ("`make-web-requests`,
  action 0: ran"), so a model that retries knows what not to redo. The
  action that ended the call is reported with its refusal reason verbatim,
  **never as "did not run"**: is_effects' `Outcome` today is `Ran |
  Refused(why)`, and a `Refused` can follow partial work (a
  `make-web-requests` refused with "sent 1 of 3"). A retry is a new intent,
  at a new place; the logbook doesn't stop it re-sending. That residue is
  the same as a model calling `send` twice by hand, and the airlock's rules
  are its bound. Accepted by Nick.
- **Pending Nick's ruling:** airlock-api-b3 has put a split of `Refused`
  to Nick (denied / failed partway / unknown). Until then the loop builds
  on `Refused`, and only the airlock's decision entry tells a deny from a
  driver failure.

### Review

A person reviews a level-0 tool in a **canonical rendering**, never the raw
positional JSON: one `propose` per line, with each argument labelled by its
name from the action's signature. The rendering is generated from the
recorded steps, so what is reviewed is what runs.

### Documents stay in drivers

`fetch` returns a **reference**: the sha256 the logbook already records.
The fetching driver writes the bytes to a content-addressed store on the
machine, keyed by that hash; other drivers only read it, and drivers never
call each other. `docxToPassage` (the docx driver) is a proposal like any
other, whose reach names the hash, so the airlock sees and decides the
read; it returns an already-bounded passage. A stranger's document is
parsed only in a confined driver, never in the core, and never copied into
the logbook.

**A trajectory may read a reference only if an outcome entry on its own
chain produced it.** Otherwise one trajectory could read another's document
by guessing or copying a hash. Owner: airlock-api-b3 with the drivers
(stage 2).

## Replying

A turn's final plain text **is** the reply (Nick, 21 Nov 23:29). The loop
hands it to the conversation's reply tool, so the model calls tools only to
act, never to speak, and a turn always reaches the person. Final text that
is empty or only whitespace sends nothing. The model never supplies the
address: the reply tool's destination comes from the trajectory's start
entry (`EntryStartsTrajectory.replyEndpoint`, written by the docking
station; Nick, 22 Nov 15:27), and the airlock's path-prefix rule for the
starting conversation is the boundary. `replyEndpoint` is null for a
trajectory started with no conversation behind it: then the loop proposes
no reply, without an error, and the final text stays only in the logbook,
as the model's turn.

**The reply is two actions** (Nick, 22 Nov 17:37), so the loop runs no
module code and the airlock still decides on the exact bytes before they
leave:

0. Run the **teams-message** app, teams_module's request-building,
   installed on the box and run by name through the program driver, with
   the final text and the bound `replyEndpoint`. It has no effect; it
   prints the Requests.
1. `make-web-requests` with exactly the Requests from that run's
   `Finished` `ExecResult.stdout`, never its `Reported` chunks, whose
   boundaries fall wherever the pipe split.

This is the first composition in the system that isn't a model's turn: a
second effect that depends on the first one's successful outcome. For now
it's the loop's own code, not a tool's steps. If the reply itself is refused, the turn ends under the
per-turn cap on tool calls and repeated refusals; the logbook shows why.

## A tool's steps are a pure function

The language is purely functional, `propose` included. A tool's steps mean
one function:

```
next(input, outcomes so far)  →  Propose(action, args)  |  Return(value)  |  Fail(message)
```

`propose` isn't an effect inside an expression. The k-th `propose` the
steps reach reads outcome k from the list; if the list has no outcome k yet,
`next` stops there and returns `Propose(action, args)`. The surface syntax
is unchanged: `propose` still sits inside `let`, as the models wrote it.

The loop's whole job for a call:

1. `next(input, [])` → `Propose(fetch, …)`; record it at (turn, intent, 0).
2. Its outcome o₀ is recorded → `next(input, [o₀])` →
   `Propose(docxToPassage, …)` at (turn, intent, 1).
3. o₁ is recorded → `next(input, [o₀, o₁])` → `Return(text)`, the intent's
   result.

Nothing is suspended or saved between outcomes: each one calls `next` from
the start. With 2 to 5 effects per tool and microsecond operations, the
repeated work (about n²/2) is negligible, and the cap on terms evaluated
bounds it. This is how Temporal and Durable Functions run workflows,
replaying deterministic code against a history of results; there the
purity is a convention, here the language can't express anything else.

## Replay

Replay is calling `next` again with the recorded outcomes. Because it is a
function, a restart gets the same next proposal; there is no separate
replay mechanism.

- **Identity is the place: (turn, intent, action).** The intent's number is
  fixed once the model's reply is recorded, which happens before its steps
  propose anything, so a restart recovers it unchanged. Each proposal is
  stored at its place. A restart calls `next` with the outcomes recorded so
  far and requires each proposal it returns to **equal** the one stored at
  that place; a mismatch (a different version, a corrupted logbook entry) halts
  the call. There's no lookup by content, so two identical `send`s in one
  tool are two places, and both dispatch.
- **One numbering, not two.** is_airlock_api 0.15.0's `PlaceInTrajectory`
  is sealed (Nick, 22 Nov 15:14 and 17:37; owned by airlock-api-b3), so
  every proposal in a turn has a place and the kinds can't be confused:
  - `ProposedForTheModelCall(turn)`, written `[turn, "model-call"]`: one
    action;
  - `ProposedForAnIntent(turn, intent, action)`, written
    `[turn, intent, action]`: an intent's actions, numbered from 0;
  - `ProposedForTheReply(turn, action)`, written `[turn, "reply", action]`:
    the reply's actions, numbered from 0 (see [Replying](#replying)).

  Within a turn the order is the model call, then intents by (intent,
  action), then the reply. 0.14's `[turn, step]` doesn't parse. There's no
  Open card; Nick dropped it at 15:14.
- **Pinned per call:** the hash of the steps (bound values included), the
  operation table's version and the action library's version. A restart on
  different versions halts the call (an error result the model sees, not a
  stuck turn).
- **Tool names are immutable within a trajectory.** Redefining makes a new
  tool, and calls already made keep their steps.

### The airlock's dispatch states

Owner: airlock-api-b3 / airlock-5c. **These states already exist in the
logbook; no new entry is needed.** The proposal entry is *proposed*. The
airlock's Allow decision entry, written durably before it calls the driver,
is *dispatched*. The outcome entry is *recorded*. An Allow with no outcome
after it is an **unknown outcome**.

Whether an unknown outcome may be re-dispatched depends on whether
**repeating the action leaves the world as it was**. That's a fixed fact
about each program, so it lives on the closed program set, not per driver
or per destination (none of ours honours an idempotency key, and
`make-web-requests` refuses every header but content-type, so a key
couldn't travel):

- **safe to repeat:** `read`, `read-bytes`, `fetch` (no effect); `write`
  (the same bytes end in the same state, though `replaced` may then say
  true); `model` (it costs money, but the loop never saw the lost reply);
- **halt, outcome stays unknown:** `start` (any executable) and
  `make-web-requests`.

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
   driver action that does its whole job. (Its two examples, `readDocument`
   fetching and reading in one action, and teams_module's card
   build-and-send, no longer hold: see [Stage 1's actions](#stage-1s-actions)
   below.) It's the same wire
   format as stage 2; the checker accepts only that one shape, and carrying
   it out is filling in the arguments and proposing. No reference ever
   reaches the model, so none can be forged or forwarded. This serves CAM
   now, and a module written against it keeps working in stage 2. Stage
   1's steps are typed exactly, in is_tools_api: an action name plus
   arguments that are each a bound value, an input field or a literal.
   Nothing delivers tools to the loop today (documents_module's
   `ToolHandler`s run nowhere), so there's nothing to migrate but
   documents_module.
   **The driver's action renders the text the model reads** (today
   `Output<O>.forModel`), so the loop builds in no module code. The loop
   adds only one uniform frame around every result, naming the tool and
   marking where the result's text begins and ends. The frame is generic,
   not module code, so a stranger's document text always arrives marked as
   a result, whatever format its driver chose. The model's exact view is
   recorded either way: the loop records every model request's rendered
   text before it's sent (`recordModelRequestOnTrajectory`). Cost: each
   action picks its own body format. (Proposed by tool-af, 22 Nov; the
   frame added here; Nick can overrule.)
2. **The term language and the evaluator**, for level 1 and for level-0
   tools of more than one action. Gate: a first workflow that needs
   composition. Nick chose **CAM's case review report** (22 Nov): it reads
   outside case data and posts a card or document to Teams. Its exact steps
   are being gathered; the evaluator is built against them, not against
   made-up examples.

### Stage 1's actions

Agreed 24 Nov by airlock-api-b3, flight-rules-af and agent-loop-21.

**A tool's action is its own closed type, `ToolAction`, in is_tools_api:**
`read`, `read-bytes`, `fetch`, or `RunExecutable(ProgramName)`. It is not a
free-text name, and it is not the airlock's `Program` set:

- No model call: it would nest model calls, and let case text leave on a
  tool's say-so.
- No `make-web-requests`: posting changes the world. The Teams send is the
  loop's reply step, not a tool.
- No `write`: no tool needs it yet.

agent_loop turns a `ToolAction` into the airlock's `Program` in one
exhaustive switch, so a new case can't compile until it's mapped. Neither
is_tools_api nor is_airlock_api depends on the other, so adding a program
to the airlock gives tools nothing new: widening what tools can do is a
decision of its own. `FlightRules` refuses rules where a given tool's
`RunExecutable` names a program not in `programsItMayRun`, the same rule
it already applies to `programsItNeeds`. A built-in isn't checked in the
rules: each call is decided on its reach.

**`readDocument` is a `fetch`** under documents_module's
`FromPathsMatching` grant. It isn't a new built-in, which would put
document knowledge into trusted driver code, and it isn't an Executable,
because a process can't be held to a path pattern.

Two things are open, and between them they decide what stage 1 can do:

1. **How a fetch tool's arguments build its `WebFetch`.** The arguments
   are positional slots (a bound value, an input field or a literal),
   which fit an Executable's argv. A fetch's input is a typed object: an
   origin, a sign-in and a path. The Graph path for a document is built
   from a bound drive and the model's file name, and joining them
   arbitrarily is `concat`, which is stage 2's term language. The options
   weighed:
   - (a) Stage 1 is RunExecutable only. Rejected: an Executable isn't
     decided request by request, it reaches whatever its suit can.
   - (b) A document built-in in the airlock. Rejected: it puts document
     knowledge into trusted code.
   - (c) The model writes whole Graph paths. Safe, since the grant's
     `FromPathsMatching` is the real limit, but the model would have to
     know Graph.
   - **(d) Recommended (airlock-api-b3): a fetch tool's path is a
     `PathPattern`, its holes filled with whole values.** is_flight_rules
     0.5.0 already has this small, reviewed language
     (`lib/src/path_pattern.dart`): literal segments, one `{name}` hole
     per segment, an optional fixed suffix for Graph's `items/F:/name:`
     form, and holes that refuse `/ \ :` and all-dots. Filling a hole with
     one checked value isn't concatenation. `read_document` becomes an
     origin, a sign-in and
     `/v1.0/drives/{drive}/items/{folder}:/{name}:/content`, with drive
     and folder bound and name from the model. The tool can point at the
     same pattern the rules grant, so the path it builds matches the grant
     by construction. It needs `PathPattern.fill(holes) → WebPath?`, null
     when a value breaks its hole's rule. **The rule has to be stated on
     the filled segment**, as flight-rules-af's probe found. `WebPath`
     refuses `..` anywhere in the raw path, and `%25` followed by `2E`,
     `2F`, `5C` or `25`. `Uri.encodeComponent` leaves `.` alone, so
     `final..docx`, `notes...txt` and `100%2Eplan.docx` all pass today's
     hole rule but are refused once encoded, and a suffix can do it too
     (`{name}.docx` filled with `report.` gives `report..docx`). So a hole
     accepts `v` exactly when `encode(v)` plus the suffix contains no `..`
     and no `%25` followed by `2E`, `2F`, `5C` or `25`, on top of today's
     checks. The test runs both ways: `fill(v)` is non-null exactly when
     the hole accepts `v`, and `matches(fill(v))` always holds. It's
     generated over realistic filenames with dots, `%`, `@`, `#`, spaces
     and non-ASCII. A test written from the rule's prose would have passed
     both earlier versions. **Where `PathPattern` lives:** is_flight_rules depends on
     is_tools_api (for `givenTools`), so is_tools_api can't depend on
     is_flight_rules without a cycle. `PathPattern` moves to
     is_web_address_vocabulary beside `WebPath` and `AddressPrefix`, and
     both packages depend on that. It meets the vocabulary rule:
     `PathPattern` and `QueryOptionName` need only `WebPath`'s neighbours
     and checked_json. is_flight_rules re-exports it, so its API doesn't
     break. tools-api-bc will admit named vocabularies to is_tools_api's
     dependency boundary, each listed by name, with a new check over
     `pubspec.lock` so a vocabulary that gains a non-vocabulary dependency
     fails is_tools_api's own tests. Its README promise becomes "nothing
     of intersyntactic's but its vocabularies".
2. **How a document's bytes become text the model reads.** A fetch of a
   `.docx` returns a zip, and the design already reads documents as
   `fetch` then `docxToPassage` ([Documents stay in drivers](#documents-stay-in-drivers)),
   which is two actions, so stage 2. A transform in the loop's own
   process is out. A parser bug triggered by a stranger's document would
   run with the loop's power to propose actions as the trajectory and to
   write its chain. The airlock still bounds each proposal by the rules,
   but the logbook record that decisions and replay rest on would no
   longer be trustworthy. That breaks "a stranger's document is parsed
   only in a confined driver, never in the core". A confined child process
   started by the loop is out too, because the loop would start a program
   the airlock never decides, and this design exists to keep exactly one
   rule: only the airlock reaches the world or starts programs. That
   leaves two options:
   - **Recommended (airlock-api-b3, agent-loop-21): stage 1 serves only
     tools whose result is already text**, such as listing a folder
     (Graph returns JSON). Reading a document waits for stage 2.
   - **If reading can't wait:** the transform is an airlock-decided run of
     a fixed program, an Executable such as `docx-to-passage` in
     `programsItMayRun`, run by the program driver in a suit with the
     fetched bytes as its input. That's a fixed two-step pipeline, fetch
     then that one run, with each step decided. It's the smallest step into
     stage 2, not a way around it, and the parser is docx-driver-ce's
     tested code.

**Decided (Nick, 24 Nov 13:11, relayed by airlock-api-b3): reading a
document can wait.** Stage 1 serves only tools whose result is already
text, such as listing a folder, with no transform and no pipeline. The
fixed fetch then `docx-to-passage` pipeline, and the content-addressed
store it needs to keep a document's bytes out of the loop and the
logbook, are stage 2's first piece, built against CAM's case review
report.

Question 1, (d), is still open.

The tool-call text format, `<tool_call>{"name", "input"}</tool_call>`
(agent_loop branch `feat/tool-calls-as-text`), serves both stages. In stage 2
a model-written definition arrives through a `define_tool` call.

## First proof (stage 2's gate)

In agent_loop, no deploy. It passes only if each of these behaves as stated:

1. Happy path: `read_document` and a `send` workflow are carried out against
   an in-memory crux, one `next` call per outcome. `next` is also tested
   alone: a list of outcomes in, one step out, no fakes.
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
   the logbook.
9. A refusal ends the call, and the model sees it.
10. An Allow with no outcome after it: re-dispatched for a program that's
    safe to repeat (`read`, `fetch`, `write`, `model`); halts as unknown for
    `start` and `make-web-requests`.
11. A malformed definition (bad JSON, an unknown form or operation, a wrong
    argument count, a wrong argument type, a free variable, a computed
    record key, oversize): rejected with an error naming the place in the
    terms.
12. A level-1 definition that names an action, carries `bound`, or calls a
    level-1 tool: rejected. `["input", "drive"]` and `["bound", "drive"]`
    read different values; a literal `"$budget.docx"` stays literal.
13. At level 0, `define_tool` isn't in the manifest.
14. A call that halts after one `send`: its error result lists the `send`,
    action 0, as ran. A call ended by a `Refused("sent 1 of 3")` reports
    that reason verbatim, never "did not run".
18. A reference produced on another trajectory's chain: the read is
    refused.
19. Input that doesn't match `input_schema`: rejected before any step, by
    the checker `Input.parse` rebuilt from the schema.
15. A value past the depth cap, a call past the allocation cap, a call past
    the cap on terms evaluated: each halts, and the loop stays responsive.
16. `substring` out of range halts; `prefix` past the end returns the whole
    string.
17. The model's spec text, the review labels and the checker's signatures
    are generated from the one operation table.

## Leads to check before building stage 2

- **CEL** (Google's Common Expression Language), **checked 22 Nov: ours
  stays.** pub.dev's `cel` (0.6.1, Oct 2026, https://github.com/atn832/cel-dart)
  is maintained and widely downloaded, but it's "a simplified port of
  cel-go" that skips cel-go's type checking: type errors are thrown at
  evaluation, where our checker rejects them at definition. It names no
  cost bound. CEL is text, so a third-party parser would read every
  module's and model's steps; and it has no notion of effects, so `propose`
  and sequencing would stay ours, with two languages in one tool. CEL fits
  as a policy expression; it doesn't fit as a tool's steps.
- **Dhall**: pure and total, every program ends. Likely heavier than we
  need.
- **Lean**, not as the tool language (its elaborator runs arbitrary code,
  so loading untrusted Lean has effects) but to **prove the evaluator**:
  replay, soundness of the checker, level 1's reach, refusals ending the
  call, and the caps. See [proving-the-evaluator.md](proving-the-evaluator.md).

## Who does what (once agreed)

- **agent_loop** (this session): the term language spec, the operation
  table, checker and evaluator; replay by place; the `define_tool` path; the
  manifest; the canonical rendering for review.
- **is_tools_api** (a session in tools_api, Nick's decision 22 Nov; its
  brief is
  `~/.claude/projects/-Users-nick-git-orgs-intersyntactic-tools-api/handover/2026-11-22T15-30-00.md`):
  `Input.parse(schema)` first; then, beside `ToolSpec`, the stage-1
  definition with `bound` and exactly typed steps. The stage-2 term
  language gets its own package, which modules write and the loop and the
  review renderer read; the definition likely moves into it.
- **is_tool** (tool-af): `ToolHandler` retired once documents_module has
  moved, not before (documents_module depends on is_tool ^0.4.0).
- **is_airlock_api / airlock** (airlock-api-b3, airlock-5c): the place as
  (turn, intent, action); "safe to repeat" on the closed program set;
  the content-addressed store and the own-chain rule for references; the
  `Refused` split (Nick's call); the level in the rules.
- **docx driver** (docx-driver-ce): `readDocument` for stage 1;
  `docxToPassage`, bytes in by reference and a bounded passage out, for
  stage 2.
- **documents_module** (documents-module-21): `read_document` and
  `list_documents` as tools sent with their steps, `DriveFolder` ids as
  `bound`.
- **teams_module** (teams-module-aa): stage 1, the card build-and-send as a
  driver action; stage 2, `reply` as a tool with steps.
