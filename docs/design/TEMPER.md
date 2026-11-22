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


# Round 4: steps, next(input, outcomes), peers folded

**Overall verdict:** RECAST (4 of 4), past the 3-round budget. **Not certified.** Stage 2 (the evaluator) is **UN-TEMPERED: do not build.** Stage 1 survives every family's strike, with the stage-1 folds below.
**Struck:** dt-1795316012, 22 Nov 2026, on head 3dee8e9 (tool-bodies-as-data.md, TEMPER.md, proving-the-evaluator.md; 53 KB; 0 cited paths not sent). Families seated: Maxwell, Noether, Carnot, Tesla (Wu disabled). Arrival order: Maxwell, then Noether, Carnot and Tesla together in one check.

## Per-family verdicts

| Family | Verdict | One line |
|---|---|---|
| Maxwell (Claude) | RECAST | The gate workflow may not need an evaluator; one intent outruns the per-turn cap; key the store by trajectory. |
| Noether (DeepSeek) | RECAST | "Each effect exactly once" isn't conserved across a retry or the loop's own unplaced effects; effects are bounded in terms, not in count. |
| Carnot (GPT) | RECAST | Stage 1 holds; re-dispatching an unknown write can destroy newer data; replay can't validate consumed proposals; resource scope undefined. |
| Tesla (Grok) | RECAST | Place, reference and re-dispatch are three loose conductors; computed paths escape review; level 1 hides payloads from the transcript. |

No family voted DISSOLVE (16 strikes over 4 rounds). Three of four (Maxwell, Carnot, Tesla) independently doubt the circumstances report needs stage 2 at all.

## Fatal flaws (deduped, most severe first)

1. **Re-dispatching an unknown outcome can destroy data.** A repeated `write` overwrites a newer write (A, lost ack, someone writes B, restart writes A). Raised by Carnot and Tesla. (This reverses airlock-api-b3's "safe to repeat" proposal from the same day; they accepted it.) Tesla's second reason, that a repeated `fetch` or `model` feeds `next` a different success, doesn't hold: an unknown outcome was never seen by the steps, so nothing they branched on can be contradicted (airlock-api-b3's correction). The write case alone carries the flaw.
   DISPOSITION: fold. **An unknown outcome always ends the call**, for every program: simpler than a per-program table, and giving up only the automatic re-read. Recovery is a new intent, as for a halt or refusal. Delete re-dispatch and the safe-to-repeat table; first-proof 10 becomes "never re-dispatched".
2. **The loop's own proposals (model call, reply, Open card) have no place.** "One numbering" is false while they sit outside (turn, intent, action), and a restart can match a reply's outcome to a tool slot. Raised by Noether and Tesla; already open with airlock-api-b3.
   DISPOSITION: fold. One place type covers every proposal in a turn; close the Open before any stage-2 build. Owner airlock-api-b3 (task 74).
3. **Effects per intent are unbounded by count, and the per-turn cap counts intents.** One call can propose up to the term cap's worth of actions; a multi-action tool evades any per-turn rule, so "composition adds no reach" holds per action but not per rate. Raised by Maxwell, Noether and Carnot.
   DISPOSITION: fold. A cap on effects per intent; the per-turn cap counts actions; one intent-wide accounting scope covers nested calls and replay work.
4. **A reference is a global name.** With `fetch` returning the bare sha256, the own-chain rule is a check on a public namespace, and a hash in input or `toText` could become a read. Raised by Maxwell, Noether and Tesla.
   DISPOSITION: fold. A reference is a capability with no literal form: no string→reference, no reference in `input_schema`. The store is keyed by (trajectory, sha256), with the trajectory half supplied by the driver from the action it's carrying out, never from the proposal (airlock-api-b3's condition). The own-chain check is deleted.
5. **The stage-2 gate may not need composition.** The circumstances report reads case data, then needs the model to write the report, then posts: judgement in the middle, so stage-1 tools serve it. Raised by Maxwell, Tesla and Carnot.
   DISPOSITION: fold. The gate requires a branch on a **successful** outcome followed by a dependent second effect with no judgement between. If the circumstances report has none, CAM stays on stage 1 and stage 2 waits for another workflow.
6. **Computed action arguments escape review.** `read_document` concatenates input into a Graph path, so `../` reaches what the reviewer never saw. Raised by Tesla.
   DISPOSITION: fold, stage 1 too. Actions take structured fields (drive, folder, name) and the driver joins them. Strike "a reviewer sees exactly what the tool reaches"; the reviewer sees bound values and the templates that still contain inputs.
7. **Replay can't validate proposals whose outcomes were already consumed.** `next` returns only the frontier. Raised by Carnot.
   DISPOSITION: fold. Replay derives the whole trace and matches every proposal to its stored one before supplying its outcome.
8. **Stage 1's compound actions put several effects behind one Allow.** `readDocument` fetches and parses; a card send may make several requests. Raised by Carnot.
   DISPOSITION: fold, stage 1. Each compound action declares its aggregate reach and partial-completion contract; narrow the visibility claim to "every action", not "every effect".
9. **Level 1 hides payloads from the model and transcript.** `fetch → send` in a standing order moves bytes without them ever being shown. Raised by Tesla.
   DISPOSITION: fold. State the grant as turn-saving and payload-hiding composition; a `call`'s outcome is exactly the callee's model-visible result.
10. **Who renders an outcome for the model is open, and stage 1 can't ship without it.** Raised by Maxwell and Tesla.
    DISPOSITION: fold, stage 1. Decide before stage 1 is called buildable.
11. **Retry residue.** A retry after a partial failure re-runs completed effects. Raised by Noether.
    DISPOSITION: named tradeoff, already accepted by Nick; the claim narrows to "at most once per call instance", and the ran-list extends to halts mid-call, not only refusals.
12. **The round-4 forms are untested with models.** Raised by Maxwell.
    DISPOSITION: fold. A model-writing experiment with controls on `input`/`bound`/`var` joins the first proof.
13. **The Lean sketches quantify over invalid histories; theorem 3 should gate level 1.** Raised by Carnot and Noether.
    DISPOSITION: fold into proving-the-evaluator.md. Define valid execution histories first; gate level 1 on theorem 3.
14. **"Can't drift" overclaims for the operation table.** Generated labels don't prove the English matches the Dart. Raised by Carnot.
    DISPOSITION: fold. The Dart is authoritative; narrow the claim to "one source"; test boundary behaviour.
15. **`Refused` conflates denied, failed partway and unknown.** Raised by Noether.
    DISPOSITION: named tradeoff, owner Nick (airlock-api-b3 has put the split to him).

## What holds

- The closed term language: unknown forms can't be written; three namespaces can't shadow; every string is literal.
- One artifact: what is sent is what is recorded, reviewed and run.
- `next(input, outcomes)` as the meaning, pins and halts on mismatch (with flaw 7's whole-trace match).
- Level 1 calls only given tools, carries no `bound`, and dies with the trajectory; level 2 deleted; `define_tool` unmounted at level 0.
- Refusals and failures end the call; bytes stay in drivers; values bounded at construction.
- **Stage 1** (one action per tool, delivered as data, no evaluator) is buildable once flaws 6, 8 and 10 are folded.

## Disposition

Four rounds are spent, past the 3-round budget, so the honest result is **not certified for stage 2**. The flaws are now concentrated in stage 2 (replay, references, effect accounting) and in the gate itself. Recommended: build stage 1 with its three folds, and freeze stage 2 until a workflow is shown to need a judgement-free chain of effects (flaw 5). If one does, fold 1–15 and strike round 5.

<!-- Each section below was written when that family returned. Arrival order, not a ranking. -->

## MaxwellMergeSlam's Design Strike

**Verdict:** RECAST

**Summary:** The frame holds and round 4 removed real producers, but the stage-2 gate may not need the evaluator at all, one intent can now outrun the per-turn cap, and the own-chain rule for references is a check where a namespace would remove the producer.

**Producer first:** Checks this design adds or hardens: (1) "a trajectory may read a reference only if an outcome on its own chain produced it". Harm: trajectory B reads trajectory A's case document. Producer: one machine-wide content-addressed store, keyed by a bare sha256, that any driver can read for any proposal naming a hash. That producer is OURS and removable: key the store by (trajectory, sha256), so another trajectory's bytes have no address a proposal could name; the own-chain check becomes unnecessary (first flaw below). (2) Re-derived proposal must equal the stored one. Harm: a restart proposes a different action than the one recorded. Producers: changed steps, operation table or action library between runs. Steps are already recorded and pinned by hash, so only the evaluator and table versions remain; keeping every shipped version runnable would remove it, but at a cost out of proportion to a rare halt the model sees. The halt stays; reason stated. (3) Level-1 checker rejecting `propose`, `bound`, calls to level-1 tools: already the producer-removed shape (the forms aren't in the level-1 grammar); fine. (4) Unknown-outcome halt for start and make-web-requests: the producer is the outside world's lack of idempotency, which we can't remove; check reviewed normally.

**Fatal flaws:**
- PRODUCER FIRST — make cross-trajectory reads impossible: key the content-addressed store by (trajectory, sha256) and have a driver's read reach name only its own trajectory's prefix; then the own-chain check ("Documents stay in drivers") becomes unnecessary. As written, a forgotten check in any one driver leaks documents across trajectories (Hart case data, in the gate workflow).
- WRONG OPTION-FRAME (the gate) — "Stages" makes CAM's circumstances report the workflow that justifies stage 2, but nobody in the bundle knows its steps, and its known shape (read outside case data, then write a report, then post a card) has a MODEL step in the middle: the report's prose is model judgement. Composition only saves turns across effects with NO judgement between them. If the report is read → model writes → post, stage 1 tools serve it fully and the evaluator has no customer. The design must first establish that the gate workflow contains a judgement-free chain of two or more effects; otherwise stage 2's gate is unmet and building the evaluator is premature.
- UNDER-COUNTED BLAST-RADIUS — the per-turn cap (on tool calls and repeated refusals, "Replying") counts intents. A level-1 tool, or a level-0 tool of several actions, turns one intent into up to (cap on terms evaluated)-bounded many effects. "Level 1 opens no doors" is true per action and false per rate: a model turn used to be the natural throttle on make-web-requests. Fold: the per-turn cap counts actions, not intents, and a level-1 tool declares or is bounded to a maximum number of effects.
- UNSTATED ASSUMPTION (evidence) — the 15/15 and 30/30 evidence was measured on `fn` parameter lists and `$`-variables; round 4 replaced both with `["input",…]`, `["bound",…]`, `["var",…]`. The doc notes it is untested, but nothing gates on it. Make "models write the new forms at least as reliably" a first-proof item, re-running experiment 2 with controls.
- MISSING FAILURE MODE (stage 1 is not buildable yet) — "Open: who turns an action's outcome into the text the model reads". Stage 1 cannot ship without an answer; for a document read it decides whether a stranger's text reaches the model raw, bounded, or framed. Settle it before calling stage 1 buildable now.

**What holds:**
- `next(input, outcomes)` as the meaning: replay as a definition, not a mechanism; testable with no fakes; Temporal's model with purity enforced by the language.
- Level 1 calling only given tools, with no `bound`: reach removed by grammar, not checked.
- Every reference a form and every string literal: removes the `$` ambiguity and the duplicated parameter list by construction.
- Dispatch states as the existing proposal / Allow / outcome entries, and "safe to repeat" on the closed program set rather than per destination.
- `Refused` reported verbatim, never "did not run".

**If RECAST, what to fold back:**
- "Documents stay in drivers": store keyed by (trajectory, sha256); delete the own-chain rule and first-proof item 18's check in favour of "another trajectory's reference has no address".
- "Stages": the gate requires a named judgement-free chain of two or more effects inside the circumstances report; if none exists, stage 2 waits for another workflow.
- "Replying" / "Effects": the per-turn cap counts actions; a multi-action tool is bounded in effects per call.
- "First proof": add a model-writing experiment on the round-4 forms, with negative and positive controls.
- "Stages", stage 1: decide who renders an outcome for the model before stage 1 is called buildable.


## NoetherNullPointer's Design Strike

**Verdict:** RECAST

**Summary:** The design's conserved quantity — "same steps + same history ⇒ same actions, each effect exactly once" — is not conserved across a retry, a partial refusal, or the loop's own un-placed effects; and the per-call blast radius is bounded in *terms*, not in *effects*, so the per-turn cap conserves nothing.

**Producer first:**

The design adds/hardens these checks. For each, the harm it exists to catch and the step that *produces* that harm:

- **Replay-equality halt** (tool-bodies-as-data.md §Replay). Harm: `fetch`'s bytes ride a `send` — a wrong effect runs. Producer: the loop consuming "the outcome recorded at this place" without checking the proposal at that place matches. **Removed**: outcomes are bound to the proposal's identity and a mismatch halts. The check is a fail-closed assertion, not a guard over a live producer. Good.
- **Version-pin halt** (body hash, operation-table version, action-library version). Harm: a drift replays a different action sequence forever. Producer: the loop not pinning what it evaluates. **Removed** by pinning. Good.
- **Input-schema check** (`Input.parse`). Harm: a malformed input reaches the steps. Producer: the loop not checking at the boundary. **Removed** by checking at the boundary. Good.
- **Definition checker** (forms, ops, types, sizes, depth). Harm: a term the evaluator can't evaluate safely. Producer: the model/module writing the term. Producer is untrusted and cannot be deleted; rejection at definition is the right shape. Good.
- **Level-1 check** (no action, no `bound`, no level-1 call). Harm: a model-written tool reaches raw actions. Producer: the model writing the definition. Untrusted; check stays. Good.
- **`define_tool` unmounted at level 0.** Harm: a level-0 model writes a tool. Producer: the manifest. **Removed** by not mounting. Good.
- **Own-chain reference check** (§Documents stay in drivers). Harm: trajectory A reads B's document. Producer: the read action accepting a raw hash. The design *also* has an opaque reference type, which should make a raw hash unrepresentable. If the type is the guard, the chain check is a second guard for a state the type should prevent — pick one. If the type is leaky (the reference is the hash with a tag the model can write), fix the type; do not add the check.
- **Retry residue** (not a check — an accepted hole, §Effects, refusals, halts). Harm: a completed `send` re-runs. Producer: **ours** — the loop allocating a new call instance for the retry. **Not removed.** This is the broken invariant. Name it, or remove it with a resume mechanism.

**Fatal flaws:**

- **"Each effect exactly once" is not conserved across a retry.** [CLASS: conserved-quantity mismatch] A partial failure or a `Refused("sent 1 of 3")` ends the call; the retry is a new intent at a new place; the completed effects re-run. The error result that "lists what already happened" is *advisory* — a producer of the double-effect (the new call instance) is alive and unguarded. The design's own words, "the same as a model calling `send` twice by hand," admit it. The invariant the design *claims* is not the invariant it *conserves*.
- **The loop's own effects have no place, and "the loop has no effects" is false.** [CLASS: broken identity / missing failure mode] §Where it runs says the loop "has no effects"; §Replay then lists "the loop's own proposals in a turn (the model call, the reply from final text)" and marks their place **Open**. The model call costs money and the reply sends a message — both are effects the airlock decides — and the model call happens *before* the reply that fixes the intent number. The address space `(turn, intent, action)` does not cover them, so replay's identity is incomplete at both ends of a turn.
- **The blast radius is bounded in terms, not in proposals.** [CLASS: under-counted blast radius] The cap is "at most 10,000 terms evaluated" and "4 MiB allocated" — a `propose` is one term, so one call may dispatch on the order of thousands of actions. The per-turn cap counts **tool calls**, and one call is one call. A single model turn can therefore drive thousands of effects through the airlock, each individually visible, none of them bounded by the cap the design points at.
- **"Composition adds no reach" is false under any per-turn rule.** [CLASS: unstated assumption] The doc's own per-turn cap on tool calls *is* a per-turn rule. A multi-action tool sends N effects in one call where the model would need N turns; the tool evades the cap. "Level 1 saves turns; it doesn't open doors" holds only if every airlock rule is per-action and stateless across actions — which the design never states and its own cap contradicts.
- **`Refused` conflates "nothing happened" with "failed partway."** [CLASS: wrong state model] A `Refused` can follow partial work (`make-web-requests` "sent 1 of 3"), so the "safe to repeat" classification — a fixed fact per program — has no entry for a partial refusal. The split (denied / failed-partway / unknown) is pending Nick's ruling, so the invariant "a refusal means retry is safe" is broken on the one path the doc names.
- **A halt is not a rollback.** [CLASS: missing failure mode] §Effects says a halt (replay mismatch, unknown outcome) "ends the call with an error result the model sees." It does not undo dispatched effects; a replay mismatch is detected *after* the airlock may have dispatched. The error list covers the `Refused` case; the design never says a *halt mid-call* also lists dispatched occurrences, so the retry blind spot of flaw 1 applies here too.

**What holds:**

- One artifact: what is sent is what is recorded, reviewed and run.
- Replay by occurrence identity `(turn, intent, action)` with a fail-closed equality halt, once the loop's own places are added.
- The pinned execution contract (body hash, table version, action-library version).
- Effects are proposals the airlock decides; actions remain a closed library people add.
- The term language is closed: no import, no host call, no loop, no recursion, no clock, no randomness, no exception other than `fail`.
- Values bounded at construction; no operation throws; out-of-range halts, `prefix` clamps.
- Refusals and driver failures end the call; the model sees them; a refusal is not a matchable value.
- Level 2 deleted; level 1 dies with the trajectory; `define_tool` unmounted at level 0.
- Bytes stay in drivers; references are opaque; a stranger's document is parsed in a confined driver.
- Stage 1 (one driver action per tool, no evaluator) proceeds on its own.

**If RECAST, what to fold back:**

- **State the conserved quantity honestly, or remove its producer.** Either add a *resume* mechanism (a retry re-enters the same call instance and continues from the first unrecorded ordinal), or rewrite the claim to "each effect at most once **per call instance**," and make the error result's occurrence list normative, not advisory. Today it is the latter with the former's rhetoric.
- **Give the loop's own effects a place.** Reserve an address for the model call and the reply (a reserved intent, or a distinct loop-level place) before the intent number exists, or move both into a driver. §Replay's "Open" is a hole in the identity scheme, not a note.
- **Cap proposals per call, and count actions — not calls — in the per-turn cap.** A term cap of 10,000 is not an effect cap.
- **State that all airlock rules are per-action, or name the composition evasion.** If any rule is per-turn, a multi-action tool evades it and "composition adds no reach" is false.
- **Split `Refused` before building stage 2**, and define "safe to repeat" for a partial refusal — the one case the current classification cannot express.
- **Make the reference an opaque type with no literal form**, so a raw hash is unrepresentable; then delete the own-chain check as redundant, or explain how a reference crosses a chain.
- **Gate level 1 on theorem 3 (level-1 reach), not just theorem 1.** The design's strongest security claim is the Lean doc's "uncertain one"; proving the easy theorem buys the wrong confidence.
- **Extend the occurrence list to a halt mid-call**, not only to a `Refused`, so a retry after a replay mismatch or an unknown outcome is not blind.

## CarnotCodeCarver's Design Strike

**Verdict:** RECAST

**Summary:** Stage 1 holds. Stage 2 still has gaps in crash recovery, replay validation and resource accounting. No real engine matches the Carnot cycle; a reviewer's job is to say how far short we are. Here, the entropy enters through recovery semantics. Dijkstra: "Simplicity is prerequisite for reliability."

**Producer first:** The harm is overwriting newer user data after a crash. The crash or lost acknowledgement is the trigger; automatically redispatching an unknown write produces the harm. That producer can be deleted: leave unknown writes unresolved unless the destination provides an atomic retry contract. Other producers are addressed below: positional outcome consumption, repeated evaluation and compound driver actions. Validation of untrusted definitions cannot disappear because accepting module- and model-supplied terms is the feature.

**Fatal flaws:**
- Make recovery overwrites impossible: remove automatic redispatch of unknown writes; then the blanket safe-to-repeat classification for write becomes unnecessary. Writing the same bytes twice is idempotent only without intervening changes. Write A, lose acknowledgement, another actor writes B, restart writes A: recovery destroys B. Safety belongs to an operation and destination contract, not merely a program name.
- The replay interface discards the evidence its equality check needs. next(input, outcomes) consumes historical outcomes internally and returns only the next proposal. Comparing that returned proposal cannot verify the earlier proposals whose outcomes were already consumed. Require each historical proposal to be exposed and matched before supplying its outcome, or explicitly make authenticated proposal/outcome history part of the evaluator interface. Test corruption of an already-consumed proposal, not just disagreement at the frontier.
- The resource contract does not compose across level-1 calls and repeated next invocations. 'Per call' could mean each given-tool invocation, each evaluator invocation, or the entire model intent. Those interpretations have different limits. A compact level-1 tool can repeatedly invoke large given tools, and replay repeats that work. Define one intent-wide accounting scope covering expanded calls, replay work, allocation and effect count. Alternatively, delete restart-from-the-beginning evaluation and retain an explicit evaluator state.
- Stage 1 moves compound work behind a single proposal while retaining the claim that every effect is visible to the airlock. readDocument fetches and parses; card build-and-send may perform several requests. One Allow can therefore cover effects the airlock never separately decides. Specify the complete aggregate reach and partial-completion contract of each compound action, and narrow the visibility claim. Otherwise staging removes the security property it claims to preserve.
- The proof statements admit histories that invalidate their conclusions. checked_never_stuck quantifies over arbitrary outcomes without requiring values to match action result types. refusal_ends quantifies over a refusal appended even beyond a tool's final action, where the evaluator may already return normally. Define valid execution histories first, including nested calls, consumed outcomes and resource accounting. Prove properties over those histories; proving the current sketches would certify a different machine.
- A shared operation table does not eliminate semantic drift. English meaning and Dart implementation remain independent entries; generated labels and signatures cannot establish their agreement. The companion document acknowledges this, while the main design claims it cannot happen. Treat executable semantics as authoritative, test their boundary behavior, and remove the stronger claim.

**What holds:**
- One recorded term artifact removes the transpiler as a separate semantic authority.
- Level 1 cannot name raw actions, supply bound values or persist across trajectories.
- Occurrence identity, immutable tool definitions and explicit unknown outcomes are the right foundations.
- Document parsing belongs in confined drivers; bounded core values and opaque references reduce blast radius.
- Stage 1 can deliver tools over the wire without building the evaluator.

**If RECAST, what to fold back:**
- Ship stage 1 with explicit compound-action reach and completion semantics.
- Remove blanket write retries; leave unsupported unknown outcomes unresolved.
- Specify replay as proposal-by-proposal history consumption, with intent-wide resource accounting.
- Obtain CAM's actual workflow before committing to stage 2. Compare model composition and one purpose-built driver action against the evaluator.
- Defer Lean implementation until the execution-history contract is precise. An oracle is useful evidence, not a proof of the Dart runtime.


## Tesla, the Arc-Prophet's Design Strike

Tesla: "If you want the secrets of the universe, think in energy, frequency and vibration."

**Verdict:** RECAST

**Summary:** Round 4 closed the term-language cage and then left three live conductors — place, reference, and re-dispatch — humming at the frequency where a restart still writes the wrong world.

**Producer first:** The design is a cathedral of checks. Name the makers of the harm.

1. **Wrong later action after a lost ack (read/write/model auto-retry).** Trigger: crash after Allow, before outcome. Producer: *The airlock's dispatch states* classifies some programs “safe to repeat” and **feeds a second success into `next`**. World-idempotent is not outcome-identical (`write.replaced`, a mutated `fetch`, a new `model` reply); steps may branch on success. **Delete automatic re-dispatch.** Unknown always ends the call (error result, turn continues) — the recovery you already accepted for halt/refusal. The safe-to-repeat table, and first-proof #10, become unnecessary.

2. **Trajectory B reads trajectory A's document.** Trigger: a hash leaks or collides. Producer: `fetch` returns **sha256 as the language-level Ref** (*Documents stay in drivers*), so a global name is the capability; *own-chain* is a look-up that can fail open. **Make Ref a per-outcome capability (the producing place, or an unguessable token).** The store may still be content-addressed behind the driver. Then own-chain (proof #18) is not a permission check on a public namespace.

3. **A reviewed tool hits a path the reviewer never saw.** Trigger: `name` is `../secrets.docx`. Producer: the flagship `read_document` **concatenates input into a Graph URL** (*The shape*), while the prose claims the reviewer “sees exactly what the tool reaches.” **Give `fetch`/`readDocument` structured fields (drive, folder, name); the driver joins them so `..` cannot climb.** Airlock prefix-on-a-computed-string becomes backup, not the boundary.

4. **A restart zips the reply (or the model call) onto a tool action.** Trigger: crash mid-turn. Producer: *Replay* asserts **one numbering**, then leaves the loop's own proposals **Open** — a second address space in the same logbook. **Every proposal in a turn, including model and reply, occupies the same place type.** Equality-on-rederive cannot save identities that have no slot.

5. **String becomes a document read.** Trigger: a hash in JSON input or `toText` of a ref. Producer: Ref is a hash-shaped value and the “No” list never forbids constructing one except from an outcome. **Refs are not JSON; no op, no `input_schema` type, no action argument accepts a string where a Ref is required.** The own-chain check is then not the thing standing between two trajectories.

6. **Retry re-sends `make-web-requests`.** Trigger: halt/unknown/refusal. Producer: a retry is a **new intent at a new place**. You cannot delete this while destinations honour no key; Nick already accepted it. Keep the “already ran” error list. Do not “fix” it with another guard.

7. **Malformed terms / wrong input / oversize / level-1 `propose`.** Untrusted bytes must cross a boundary; `Input.parse`, definition checking, and “`propose` is inexpressible at level 1” stay. `define_tool` unmounted at level 0 is already producer-first (good). Caps-at-construction already make runaway values unrepresentable (good).

**Fatal flaws:**
- **The place is still two clocks.** *Replay* (“One numbering, not two”) plus the Open line: model call and reply have no intent, so they do not live at `(turn, intent, action)`. Round 1's zip was “outcomes ride `[turn, step]` onto a different action.” You renamed the triple and left the loop's effects off it. At 3am a restart will ask the airlock for “action 0” and the reply will answer. Proofs 2–6 never spawn a loop proposal. Fold: one place sort for every propose in the turn; close the Open before stage 2.
- **Unknown + “safe to repeat” re-enters a different success.** *The airlock's dispatch states* and proof **#10**. Tesla: "The spread of civilisation may be likened to a fire; first, a feeble spark, next a flickering flame, then a mighty blaze, ever increasing in speed and power." You doused automatic re-dispatch in round 2, then relit it for four programs. `next` is allowed to `if` on a successful outcome. A second `write`/`fetch`/`model` is a different note in the chord. Fold: unknown always halts; repeating is a new intent.
- **`bound` is a prefix, not a reach.** *A tool definition is one JSON object* / *What the operator grants*. Three namespaces cannot save a fourth: the **computed argument**. Review renders labelled args; it cannot freeze a URL that still contains `["input", "name"]`. Fold: no free-form URL from terms; structured action args; strike the sentence “a reviewer sees exactly what the tool reaches.”
- **Ref = sha256 makes the own-chain rule a check on a global name.** *Documents stay in drivers*. 256 bits of content-address is a doorbell anyone who knows the file can ring. Proof #18 is that doorbell's bouncer. Fold: Ref is a capability; hash never enters the term language; no string→Ref (add it to the “No” list and to proof #12).
- **Level 1 is not “saves turns.”** *What the operator grants*. A standing order `fetch → send` moves bytes **drive → Teams without the payload entering the model or the transcript**. The model doing the same in two calls must show the text. That is a confidentiality door, and it gets wider if `Output.forModel` (the Open in *Stages* §1) is a thinner projection than the value `call` sees. Fold: state the grant as closed-loop composition **and** payload-hiding; pin that a `call`'s outcome **is** the callee's model-visible result, same bytes.
- **Stage 2's gate may not be a language.** *Stages* / *First proof*. CAM's circumstances report is “read outside case data and post a card.” That is **one driver action**, or two stage-1 tools with the model in the middle — the shape Maxwell named and you staged. Building the evaluator *against that workflow* resonates at the wrong harmonic: you will certify a language on an example that did not need one. Fold: either pick a gate that *requires* `if`/`let`/`call` (branch on a successful fetch, then a second effect), or keep stage 1 as the CAM path and do not light the evaluator for it.

**What holds:**
- The closed term language: no host, no import, no loop, no clock, no RNG — unknown forms cannot be written. Three namespaces that cannot shadow. That cage is real.
- One artifact: the JSON that is sent is the JSON that is recorded, rendered, and run. The transpiler is dead. Stay that way.
- `propose` / `call` split by level; level 2 gone; `define_tool` not mounted at 0. Recursion cannot be written. Two-deep is a hard lid.
- Refusals and driver failures are not values; they end the call. `fail` is a standing order, not a probe.
- Bytes stay in drivers; core values are bounded at construction; the operation table is the one generator for spec, labels, and checker.
- `next(input, outcomes) → Propose | Return | Fail`, replay as the same function, pin hashes, halt on mismatch. For *tool* proposes, that chord is in tune.
- Stage 1's “one action per tool, no reference to the model” is a buildable subset. documents_module can move without an interpreter.
- The positional-term experiments (30/30, 15/15) are honest: “no evidence the model struggles,” and the untested `input`/`bound`/`var` forms are flagged.

**If RECAST, what to fold back:**
- **Replay:** Define place as covering *every* proposal in a turn (model, each intent's actions, reply). Delete the Open or it is a second numbering. First proof: crash between model-call and first tool action; crash between last tool action and reply; both resume at the stored place, never a tool slot.
- **Dispatch:** Unknown outcome **always** ends the call. Strike “safe to repeat” auto re-dispatch and proof #10. Recovery = new intent (already the halt/refusal story).
- **Documents / values:** Ref is a capability derived only from an outcome on this call; sha256 is driver-internal. Add to the No-list and to proof #12: no string→Ref, no Ref in `input_schema`, `toText(ref)` is not an address.
- **Actions:** Graph/file reads take `(drive, folder, name)` (or equivalent), not a concatenated path. Rewrite the `read_document` example. Replace “reviewer sees exactly what the tool reaches” with “reviewer sees bound values and the templates that still contain inputs.”
- **Grant:** Level 1 = turn-saving **and** transcript-hiding composition over given tools. Pin `call` outcome = that tool's model-visible result (close the stage-1 Open in the same sentence).
- **Gate:** Stage 2's first proof workflow must contain a branch on a **successful** outcome and a second effect that depends on it. If CAM's report does not, it stays stage 1.
- **Proof list:** Renumber 1–19 as one sequence; add places-for-loop-proposals, unknown-never-redispatches, string↛Ref, structured fetch args.

Nine is completion; you are on four. The spark is alive — do not ship the interpreter until the place, the Ref, and the lost-ack story are one circuit, not three.
