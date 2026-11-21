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
