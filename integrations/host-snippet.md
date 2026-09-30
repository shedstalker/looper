# Host prompt snippet

A short paragraph for systems whose prompts start agents on work that deserves independent
review: a build pipeline's builder prompt, maintenance briefs, a team's agent guidelines. Paste
it as is. Everything else is in the Looper files it points to.

```text
Independent review (Looper): when this work reaches a checkpoint that would be costly to get
wrong - a design or plan others will build on, a change to shared or production code, a
migration, or a final result - ask an independent second agent to review it before relying on
it. Use Looper: say "Use Looper for this task", or read <looper home>/prompts/worker.md. Offer an
exact candidate: a commit and tree for source, or `publish ... handoff -Attach <file>` for
documents outside Git. Carry on with independent work while you wait, act on the verdict (PASS,
REPAIR or BLOCKED), and treat a PASS as evidence, never as permission for anything the task has
not already allowed. Small, easily reversed steps do not need it.
```

Replace `<looper home>` with the Looper folder or Skill install on that machine.
