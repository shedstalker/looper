# PLAN

Keep this proportional: a trivial task needs a few lines per heading. PLAN is the task
boundary, not an implementation recipe. Change it only for a real change of goal or scope,
and note that change in TASK.md.

## Outcome
What observable state must be true when this task is complete?

## Context
Where the work is (repo, branch, folders), the current state, and the references needed.

## Boundaries
- Allowed: what the worker may change and run.
- Not allowed: out of scope.
- Reserved for the human: e.g. merge, push, deploy, install, external writes, goal changes.

## Proof
What evidence shows the outcome is met, including important negative cases.
The reviewer independently checks meaningful checkpoints and the final state.

## Escalation
When to stop and ask the human instead of continuing. Park isolated blockers in TASK.md and
carry on with independent work; stop the loop only when nothing useful can safely continue.

Worker freedom: inside this boundary the worker chooses the approach, order and tests.
