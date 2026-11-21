# TEMPER.md — Tool bodies as data

**Overall verdict:** RECAST (4 of 4 families)
**Struck:** dt-1795257327, 21 Nov 2026, families seated: Maxwell + Noether, Carnot, Tesla (Wu disabled)
**Bundle:** `tool-bodies-as-data.md` only; the cited-but-not-sent check ran: 0 cited paths, 0 not sent.

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Maxwell (Claude) | RECAST | An interpreter at the center of a problem today's tools don't need one for; make escape impossible instead of checking twice. |
| Noether (DeepSeek) | RECAST | "Same body + same history ⇒ same actions, each effect once" isn't conserved across redefinition, library change, or a crash between execution and record. |
| Carnot (GPT) | RECAST | The goal holds; the proof doesn't. Specify the action lifecycle and a minimal typed evaluator before choosing Dart. |
| Tesla (Grok) | RECAST | A host-language interpreter, refusals as matchable values, and outcomes zipped onto `[turn, step]`: one restart later, recorded bytes land on a different action. |

## Fatal flaws (deduped, most severe first)

1. **Replay binds outcomes by position.** A restart feeds "the outcome recorded at this place" to whatever proposal re-evaluation produces there. If the body, the action library or the evaluator drifted, fetch's bytes ride a send. Raised by Tesla, Carnot, Noether and Maxwell.
   DISPOSITION: fold. Every outcome is keyed by the proposal's digest (action, arguments, body identity). A re-derived proposal that doesn't match the recorded one **halts** the call. It never consumes the old outcome.
2. **No pinned execution contract.** Body redefinition, action-library change, value-type helpers (`Passage.cut`, `drivePath`) and evaluator upgrades all move the action sequence. Raised by all four.
   DISPOSITION: fold. Tool definitions are immutable per name within a trajectory (a redefinition is a new name). Each call records the body's content hash, the action library's version and the evaluator's version, and a mismatch on restart halts the call (see 1).
3. **The evaluator is a host-language interpreter guarded by two denylists.** A Dart subset sits on a machine that can run full Dart; analyzer and interpreter are two opinions of one subset that will drift; `dart:core` is implicit, so methods on allowed types (`String`, `RegExp`, `*`) are unbounded. Raised by Tesla, Carnot, Noether and Maxwell.
   DISPOSITION: fold, reversing the language recommendation. The body language is a **closed term language** with its own small evaluator. Its only non-pure form is "propose this declared action and suspend". It has no import form and no host call, so an unknown form is inexpressible, not rejected. Dart syntax may be a *front end* that compiles to those terms (Carnot); it is never the thing evaluated. JSON-encoded Lisp is a candidate for the terms (Tesla). `analyzer` leaves the trust boundary.
4. **"A tool adds no reach" understates the grant.** A body conditions later effects on earlier outcomes without a model turn: closed-loop composition at evaluator speed, hidden from the model (fetch, branch, send). At level 1 a model-written body can also call any action in the library, not only those behind its given tools. Raised by all four.
   DISPOSITION: fold. Rewrite the safety section: per action, a tool adds no reach; what level 1 grants is closed-loop composition the model and airlock don't see as a whole, over the full action library. Name that as the power the operator grants.
5. **Duplicate effects across a crash between execution and outcome record.** Raised by Noether and Carnot.
   DISPOSITION: fold, with a correction. In this system the proposal entry is already durable intent with an identity, written before the airlock decides, and a restarted loop that finds its proposal in the record waits for that proposal's outcome instead of proposing again. The remaining window is the **airlock's**: it dispatched, then died before recording. State the contract: one dispatch per proposal id; a dispatched-but-unrecorded proposal becomes an *unknown outcome* that halts the call and is never automatically re-dispatched. Owner: airlock-api-b3 / airlock-5c.
6. **Document-sized data in the core and the logbook.** `fetch(…, keep: bytes)` → `docxToText` → `Passage.cut` pulls the stranger's document through the core. A zip bomb, expanded XML or a pathological `RegExp` needs no loop. Every document also becomes a permanent logbook entry. Raised by Tesla and Maxwell.
   DISPOSITION: fold. Core values are small scalars and **references** to outcomes. Actions take references, and the driver returns an already-bounded result (docx driver: bytes in by reference, a bounded passage out). Price logbook size and retention for fetched bodies, or let a pure action read the bytes from the fetching driver without recording them twice.
7. **A refusal as a matchable value lets a body probe the airlock.** A body can learn which names, sizes or recipients fail and adapt, unseen. Raised by Tesla.
   DISPOSITION: fold. A refusal ends the call, and the model sees it as the call's error result.
8. **Level 2 (saved model-written tools) is the producer of cross-rule behaviour; approval is only its guard.** Raised by Tesla; versioning concerns from Noether and Maxwell.
   DISPOSITION: named tradeoff for **Nick** (it touches his self-modification goal). Recommendation: delete level 2. A model-written body dies with its trajectory, and a tool worth keeping becomes source a person merges into a module. "Load at run time" (21:33) is served by level 1.
9. **Resource bounds by budget instead of by construction.** Raised by Tesla, Carnot and Maxwell.
   DISPOSITION: fold. No loops and no recursion in the term language; core values bounded (see 6). Evaluator cost is then bounded by body size, and the step budget is no longer the safety.
10. **Where the evaluator runs.** Carnot calls the loop "privileged". It isn't: the loop holds no sign-ins or secrets (`bin/agent_loop.dart`'s own contract). The isolation point still stands for blast radius: a runaway evaluation stalls the trajectory's loop. Raised by Carnot and Tesla.
    DISPOSITION: named tradeoff, owner agent_loop. With 3 and 9 folded, evaluation is bounded by body size, so in-process is acceptable for level 0 and 1. Revisit if the term language ever grows loops.
11. **Ordering of several tool calls in one turn.** Raised by Noether.
    DISPOSITION: already handled. The text format allows one call per reply, ending it, so calls are sequential. State it in the design.
12. **The interpreter isn't needed for any tool that exists today.** The heavy computation can live in drivers, so today's tools are one action or a fixed short sequence. Raised by Maxwell, partly Carnot.
    DISPOSITION: fold as staging. Stage 1: tools are actions or fixed sequences, ids in the manifest, no evaluator. Stage 2: the term language and evaluator, for level 1.
13. **The first proof only tests the happy path.** Raised by all four.
    DISPOSITION: fold. The pass condition is each of these **failing closed**: a replay that derives a different proposal (halt), a body redefinition (new name, old calls pinned), an action-library version change (halt), an outcome too large for the core (unrepresentable), a refusal (ends the call), a dispatched-but-unrecorded proposal (unknown, no re-dispatch). Plus the suspend-and-resume demonstration. Prove one read workflow and one send workflow across crash boundaries.

## What holds

- A signature in the manifest and a body as data in the record. A body can be read before it runs; a closure can't.
- Every effect is a proposal the airlock decides, and actions remain a closed library people add. A model composes them; it never mints a new kind of effect.
- Strangers' bytes are parsed in a confined driver with a reach type of its own, never in the loop.
- Replay against recorded outcomes, once outcomes are bound by proposal identity and the execution contract is pinned.
- Levels 0 and 1 as the operator's choice of power.
- Survives from today: the tool-call text format, `ToolSpec`, and proposals that point at earlier outcomes by identity.

## Disposition

RECAST. Fold 1–7, 9, 11, 12 and 13 into `tool-bodies-as-data.md`. Put 8 to Nick. Record 10 as a tradeoff. Re-strike after the fold (round 2 of at most 3).

---

# Round 2: Dart, transpiler, closed term language

**Overall verdict:** RECAST (4 of 4 families)
**Struck:** dt-1795260122, 21 Nov 2026, the recast design plus round 1's TEMPER.md; families seated: Maxwell + Noether, Carnot, Tesla.

| Family | Verdict | One line |
|---|---|---|
| Maxwell (Claude) | RECAST | "Halt" is undefined, and stage 1's "fixed sequence the loop runs" is the code-in-the-loop the design removes. |
| Noether (DeepSeek) | RECAST | The cost bound, the proposal's identity and the transpiler's "outside the boundary" each break. |
| Carnot (GPT) | RECAST | The closed evaluator is a real improvement; resource bounds, occurrence identity and the transpiler's authority remain unproved. |
| Tesla (Grok) | RECAST | Three tones (the Dart read, the terms run, the proposal heard). A licensed-wrong transpiler plus pinning replays the wrong send forever. |

Closed by round 2 (all families agree): escape is inexpressible in the terms; a refusal is not a value; the grant is named honestly; tool names are immutable; one call per reply; terms recorded, not Dart.

## Fatal flaws (deduped, most severe first)

1. **"Wrong, never unsafe" is false.** Every effect is a `propose`, which the terms have, so a mistranslation is a wrong action, argument or branch that the airlock may permit, and pinning replays it forever. Three artifacts (the Dart a person reads, the terms that run, the proposals) can disagree. Noether adds that `analyzer` on model-written source in the loop resolves `file:///` URIs before rejecting them. Raised by all four.
   DISPOSITION: fold, with Nick choosing among three: (a) delete the transpiler and have the model write the terms (Tesla); (b) keep Dart as a front end but make the **terms** the reviewed and approved artifact, rendered canonically, with the transpiler run parse-only on in-memory sources in a confined worker (Noether, Carnot); (c) an existing language the model already knows that has the properties itself, so the language written is the language run (Nick, 22:25: see the session note on Starlark).
2. **Exponential growth with no loop.** `s = s + s` n times, or `x = x * x`, is exponential in body size; integers are unbounded. "Bounded by body size" is false. Raised by Noether, Carnot and Tesla.
   DISPOSITION: fold. A maximum width on strings, lists and integer magnitude, enforced at every constructor, and the call halts on overflow. Delete the composition claim, and keep in-process evaluation only on this basis.
3. **A digest is not an occurrence.** `await send(m); await send(m);` gives two proposals with one digest, and a later call with the same arguments aliases an earlier one. Raised by Noether, Carnot and Tesla.
   DISPOSITION: fold. Identity is (call instance, ordinal); the proposal is stored at that ordinal; re-derivation must equal it, and a mismatch halts. No lookup by content across ordinals or calls. The digest is an assertion, not a key.
4. **No dispatch state machine.** The record can't tell "dispatched" from "died before dispatch", so "one dispatch per proposal" is an aspiration. Raised by Noether, Carnot and Tesla.
   DISPOSITION: fold, owner airlock-api-b3 / airlock-5c. Proposed → dispatched (durable before the effect) → recorded. Drivers treat (call instance, ordinal) as an idempotency key, and a retry reuses the occurrence id. "Never re-dispatch" becomes a liveness choice.
5. **Fetched bytes still default to the logbook.** Raised by Noether and Tesla.
   DISPOSITION: fold. The log holds the proposal and a hash; the bytes stay with the fetching driver; the parsing driver reads them by reference; retention is the driver's. A width cap makes a fat outcome unrepresentable in the core.
6. **The example isn't a legal term program.** `graph`, `drive`, `folder`, `drivePath` and `Passage.refusedBecause` come from nowhere. Raised by Tesla.
   DISPOSITION: fold. Ids are recorded arguments of the call; helpers are term operations; a body calls no other body.
7. **Driver-shaped denials reopen probing.** An outcome saying not-found or too-large can be switched on. Raised by Tesla.
   DISPOSITION: fold. Action outcomes are success-only; every denial is the airlock path that ends the call.
8. **Partial operations.** Dart's `substring` throws; term operations are total. Raised by Noether and Carnot.
   DISPOSITION: fold. Each operation is defined as total (an out-of-range call halts the call), or the front end rejects it.
9. **"Halt" is undefined.** Every deploy changes the evaluator version. Raised by Maxwell.
   DISPOSITION: fold. A halted call ends with an error result the model sees, and the turn continues.
10. **Stage 1 sequences are a closure in the loop.** Raised by Maxwell. Tesla would allow a single driver action holding the suffix check and parse.
    DISPOSITION: fold. In stage 1 the model composes: actions are the tools, one action per call.
11. **Stage 2 needs a demonstrated need.** Raised by Carnot.
    DISPOSITION: named tradeoff for Nick. Self-modification is his stated goal (21:33); the gate is a first level-1 workflow chosen with him.
12. **Level 2 is still in the closed set.** Raised by Noether, Tesla and Carnot.
    DISPOSITION: Nick's answer still pending. Remove it from the set until he answers.
13. **The proof doesn't try to break the new claims.** Raised by all four.
    DISPOSITION: fold the listed cases: identical proposals both dispatch, a second call doesn't reuse the first's outcome, width overflow halts, no raw bytes in the log, a `file:///` import is never read, out-of-range `substring`, a retry after unknown reuses the occurrence id.

## Disposition

RECAST, round 2 of 3. Flaw 1 is the fork, and it's Nick's: transpiler, terms written directly, or an existing language. The others fold regardless of which he picks.

---

# Round 3: the model writes JSON terms (final round)

**Overall verdict:** RECAST (4 of 4), final round of 3. **Not certified:** UN-TEMPERED for build until the folds below land and a fresh strike passes.
**Struck:** dt-1795263356, 21 Nov 2026; families seated: Maxwell + Noether, Carnot, Tesla.

Closed by round 3 (all agree): the transpiler is gone (one artifact); occurrence identity replaces content identity; dispatch states are explicit; bytes stay in drivers; level 2 is deleted. No family voted DISSOLVE in any of the 12 strikes: the frame has held, and the remaining flaws are contracts.

## Fatal flaws (deduped)

1. **`bound` is not a boundary, and level 1 grants the whole action library with any arguments.** The model writes the whole level-1 definition, `bound` included, and input and bound names can collide. Raised by Noether, Carnot, Tesla and Maxwell.
   DISPOSITION: fold. **A level-1 body may call only the trajectory's existing tools** (with their bound values), never raw actions. Then "composition adds no reach" is true at the tool level. `bound` lives in its own immutable namespace that inputs can't shadow, set by whoever wrote the tool (a person, for level 0), and pinned per call with the body hash.
2. **A retry after a halt or refusal re-sends completed effects** under a fresh call instance. Raised by Tesla, Carnot and Noether.
   DISPOSITION: fold plus a named tradeoff. A call instance is allocated and recorded before its first proposal, and recovered unchanged. A halted call's error result **lists the occurrences that completed** ("send at ordinal 0: done"), so the model doesn't redo them blind. The residue is the same as a model calling `send` twice by hand: owner Nick, accepted, with the airlock's rules as the bound.
3. **Aggregate sizes are unbounded** (nesting, sharing, records). Raised by Carnot, Tesla and Noether.
   DISPOSITION: fold. A cap on each value's total serialized size and on its depth, a cap on the call's total allocation, and a step budget per call, all enforced at construction.
4. **"Success-only" overclaims.** Driver failures, domain misses and lost acknowledgements are conflated, and successful results still carry information. Raised by Carnot, Tesla and Maxwell.
   DISPOSITION: fold, narrowing the claim. Guarantee only that a body can't branch on an **airlock refusal or a driver failure**: both end the call. Successful results carry information by design. A lost acknowledgement on an effect is an unknown outcome, not a failure. "Exists or else" needs a list then a read.
5. **Stage 1 passes references through the model**, which makes them forgeable and forwardable. Raised by Tesla and Maxwell.
   DISPOSITION: fold, taking Tesla's shape. A stage-1 tool is **one driver action** that does its whole job (the docx driver's `readDocument`, teams_module's card build-and-send). No reference ever reaches the model.
6. **`substring` clamping silently truncates.** Raised by Tesla.
   DISPOSITION: fold. A clamped `prefix(s, n)` exists for "the first n characters"; an out-of-range `substring` halts the call.
7. **`define_tool` exists at level 0.** Raised by Tesla.
   DISPOSITION: fold. At level 0 the tool isn't mounted at all: a producer removed, not a check.
8. **A person may misread positional JSON and merge it at level 0.** Raised by Tesla.
   DISPOSITION: fold. Review uses a canonical rendering (each `propose` on its own line, with argument names from the table).
9. **"Unknown, no re-dispatch" could re-dispatch safely,** since drivers are idempotent by occurrence. Raised by Noether.
   DISPOSITION: named tradeoff, owner airlock-api-b3. Re-dispatch only where the destination honours the key; halt where it can't.
10. **Call instance undefined; `record` form unspecified; action-argument types unchecked at definition.** Raised by Noether, Carnot and Maxwell.
    DISPOSITION: fold. Call instance = the recorded tool call's entry id. Specify `record`. Check argument types against the action signatures at definition time.

## Disposition

Three rounds are spent. The design is **not certified**. Fold 1–10, then a fresh strike before any stage-2 build. Stage 1 (5) can proceed on its own: one driver action per tool, no evaluator.
