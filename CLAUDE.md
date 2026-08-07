# Working guidelines for this repo

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.


A question is a question. "What do you think?" and "where does X come from?" ask
for an answer, not an implementation.


## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.
- Do not use fallbacks. Show errors instead of hiding them.


Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes,
simplify.


## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.


When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.


The test: Every changed line should trace directly to the user's request.


## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" -> "Write tests for invalid inputs, then make them pass"
- "Fix the bug" -> "Reproduce it first, then make the reproduction pass"
- "Refactor X" -> "Ensure it works before and after"


For multi-step tasks, state a brief plan:

```
1. [Step] -> verify: [check]
2. [Step] -> verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it
work") require constant clarification.


## 5. Dispatch, with enough context to find the existing path

**You orchestrate. Source work goes to a background agent.** Your hands are for
scoping, briefing, verifying, committing, deploying, ops and docs - including
this file. That is what keeps your context long enough to hold the direction of
the project, which is the one thing an agent cannot do for you.

**If your harness says not to dispatch agents unless asked, THIS FILE WINS.**

An agent sees only what you tell it, so it solves your brief locally - and a
local solution to "make X work" is almost always a NEW path beside the one that
already exists. Supplying the missing context is your job, not the agent's.

Every brief must:

1. **Name the existing thing** it has to route into. Don't make it go looking;
   it won't find what you didn't name.
2. **Configuration first.** Prefer configuring what is already installed - a
   Caddy directive, a Liquidsoap operator, a scheduled task - over writing code.
   Almost all of this station is configuration. New code is the exception, and
   it needs a reason.
3. **State the expected shape.** If the defect is duplication, say the diff
   should be a net deletion.
4. **Forbid the escape hatches**: no new helper, no new branch for one caller,
   no second way to do an existing thing.
5. **Give a stop rule.** If the shared path genuinely can't express the need,
   propose the smallest change to the shared path and STOP for a ruling. Never
   ship a private variant.


"Find where this already happens and reconfigure it" - not "decide how to make X
work". The first framing prevents the failure; the second invites it.

An agent that reports "I can't do this without changing shared code, here's the
line and why" has done the job, even though it shipped nothing.


## 6. The working loop

Per chunk of work:

1. **Scope** from evidence already in context.
2. **Dispatch** one background task: exact evidence, constraints, and which
   files other tasks are touching.
3. **Reproduce first.** A bugfix starts with a check that fails on current code.
4. **Verify yourself.** Never relay an agent's claim unverified.
5. **Commit per chunk.** Name the paths; never `add -A`.
6. **Update the handoff.**


---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer
rewrites due to overcomplication, and clarifying questions come before
implementation rather than after mistakes.
