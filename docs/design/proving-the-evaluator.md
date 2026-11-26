# Proving the evaluator with Lean

Status: idea, 22 Nov 2026. A companion to
[tool-bodies-as-data.md](tool-bodies-as-data.md). Nothing here is built, and
none of it should start before stage 2's evaluator exists and passes its
first proof.

## Why

Three design-temper rounds came back RECAST 4/4, every time on **arguments**:
"replay re-derives the same proposals", "a level-1 tool adds no reach",
"every call ends". Reviewers can only weigh an argument. A proof they can
check.

The part that carries those claims is small. A tool's steps mean one pure
function,

```
next(input, outcomes so far)  →  Propose(action, args) | Return(value) | Fail(message)
```

and the evaluator that computes it is a few hundred lines. That is the shape
that formal verification handles well: a small core everything else trusts,
proven once, as seL4 does for an operating-system kernel and CompCert for a
C compiler. Lean 4 is a purely functional language with a proof checker
built in, so `next` can be written in it nearly as it is defined and then
reasoned about directly.

Lean is **not** the language tools are written in. Running Lean code from a
module or model means running Lean's elaborator on it, and macros, tactics
and `#eval` run arbitrary code during elaboration, file and network access
included. Lean here is the place the evaluator is specified and proven, by
us, at build time.

## The model

A sketch, not checked Lean. The real thing follows the operation table and
the forms in the design doc.

```lean
inductive Value where
  | str    : String → Value
  | int    : Int → Value
  | bool   : Bool → Value
  | list   : List Value → Value
  | record : List (String × Value) → Value
  | ref    : RefId → Value

inductive Outcome where
  | done    : Value → Outcome
  | refused : String → Outcome
  | failed  : String → Outcome

inductive Step where
  | propose : Action → List Value → Step
  | ret     : Value → Step
  | fail    : String → Step
  | halt    : HaltReason → Step
  | stuck   : Step   -- a run-time type error; the theorems say it never happens

/-- What a tool's steps mean. -/
def next (t : Tool) (input : Value) (outcomes : List Outcome) : Step := …

/-- The proposals a call has made, given the outcomes recorded so far. -/
def trace (t : Tool) (input : Value) (outcomes : List Outcome) :
    List (Action × List Value) := …
```

`stuck` exists only in the model. It names the failure a type checker is
supposed to rule out, so a theorem can say it never occurs.

## What to prove

In order of value, with the claim each one replaces.

1. **Replay finds what it left.** If a call has recorded some outcomes and
   more arrive, the proposals already made are unchanged: the earlier trace
   is a prefix of the later one.
   ```lean
   theorem replay_prefix (t input os more) :
       trace t input os <+: trace t input (os ++ more)
   ```
   This is the property every restart rests on. Determinism of `next` itself
   is free in Lean, since every function is one; the content is that the
   k-th `propose` depends only on outcomes 0 to k−1.

2. **A checked tool never gets stuck.** Every definition the checker accepts,
   given input that matches its schema, evaluates to a proposal, a result, a
   failure or a halt, never to a type error.
   ```lean
   theorem checked_never_stuck (t) (h : check t = .ok) (input) (hi : conforms input t.schema) (os) :
       next t input os ≠ .stuck
   ```
   This is the classic soundness theorem for a type checker, and it proves
   fold 10's "argument types checked at definition" actually does its job.

3. **Level 1 opens no doors.** Every action a level-1 tool proposes is one a
   given tool proposes, with that tool's bound values.
   ```lean
   theorem level1_reach (given) (t) (h : checkLevel1 given t = .ok) (input os) :
       ∀ p ∈ trace t input os, ∃ g ∈ given, CanPropose g p
   ```
   `CanPropose g p` says some input and outcomes would lead `g` to propose
   `p`. This is the strongest security claim in the design, and today it's
   only an argument.

4. **A refusal ends the call.** Once a refused or failed outcome is in the
   list, `next` returns `fail`, whatever the steps say.
   ```lean
   theorem refusal_ends (t input os reason) :
       ∃ m, next t input (os ++ [.refused reason]) = .fail m
   ```
   So steps can't branch on what the airlock refused.

5. **Every call ends within the caps.** Every value stays within the size
   and depth bounds, and `next` evaluates at most the capped number of terms
   before returning a step or `halt`. In Lean this is partly by
   construction, since `next` must be shown to terminate to be defined at
   all; what's left to prove is that the bounds are invariants.

## Keeping the Lean and the Dart in step

A proof about the Lean model says nothing about the Dart that runs, unless
something ties them together. This is the same drift the operation table
had (English for the model, Dart for the machine), one level up. Three ways,
cheapest first:

- **Lean as the oracle.** Compile the Lean `next` to a command-line program
  and run both it and the Dart evaluator on generated tools and outcome
  lists, comparing every step. Cheap and strong in practice; it tests
  agreement, it doesn't prove it.
- **Generate both from one table.** The operation table already generates
  the model's spec text, the review labels and the checker's signatures.
  It could generate the Lean definitions of the operations too, leaving
  only the walk itself written twice.
- **Run the Lean.** Lean compiles to C, and Dart can call C through
  `dart:ffi`, so the proven `next` could be the one that runs. Then the
  proof covers the running code, at the cost of building and shipping a C
  library with Lean's runtime inside the loop's process. Worth it only if
  the oracle keeps finding disagreements.

## What it doesn't cover

- The airlock's decisions and the trajectory's rules.
- The drivers, and whether an action does what its name says.
- Whether the operation table's one-sentence meanings say what its Dart
  does; generating the spec from the table narrows that, a proof doesn't.
- The Lean model matching the Dart, short of the third option above.

## How much work

A guess, and where it thins. Theorems 4 and 5 are small. Theorem 1 follows
from how `next` reads outcomes by position, and should be modest. Theorem 2
is standard but long: a type system for the terms, then progress over every
form and operation. Theorem 3 is the uncertain one: stating `CanPropose`
well, and handling bound values, will take more thought than the others
put together. A first pass at theorems 1, 4 and 5 could be a few days;
2 and 3 are where it could grow.

## When

After stage 2's evaluator passes its first proof in Dart, and before
level 1 is switched on for any trajectory, since level 1 is where theorem 3
matters. Start with the oracle and theorem 1; they pay off even if the rest
never lands.
