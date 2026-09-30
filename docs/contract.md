# Looper L1 contract

The stable part of Looper. Everything here is provider-neutral and can be followed by hand;
`tools/looper.ps1` just does it reliably. Drivers, watchers and provider syntax are replaceable
implementation details and are deliberately not part of this contract.

## Roles

- **WORKER** - does the task inside PLAN, keeps TASK current, publishes HANDOFFs, writes FINAL_REPORT.
- **REVIEWER** - an independent second agent that answers each handoff. Usually a review, but
  a handoff may request research, a comparison, or access the worker lacks.
- **Human** - sets the task, starts both agents once, keeps reserved decisions.

Any capable agent can take either role. Worker and reviewer should be separate sessions,
preferably different models or providers, so the review is genuinely independent.

## Task folder

```text
<folder>/                (usually <project>/.looper, kept out of commits via .git/info/exclude)
  CONTEXT.md             router: what this task is, where things are, what to read
  PLAN.md                boundary: outcome, context, boundaries, proof, escalation
  TASK.md                shared live working memory (free-form)
  FINAL_REPORT.md        closeout (template until written)
  EXCHANGE/HANDOFF.md    worker's current request      (template until first publish)
  EXCHANGE/REVIEW.md     reviewer's current answer     (template until first publish)
  HISTORY/               NNN_HANDOFF.md, NNN_REVIEW.md - every published exchange, in order;
                         NNN_attachments/ - snapshots of a handoff's attached files
  WATCHERS/              wake-up notes, driver locks and logs
```

A file whose text contains `<!-- looper:template -->` counts as not yet written.

## Identity

- A handoff's **id** is the SHA-256 of its exact bytes; `status` shows the first 12 hex digits
  and its HISTORY number, e.g. `003 ab12cd34ef56`.
- A published handoff is immutable. Changing anything means publishing a new handoff, and a new
  handoff never repeats the exact text of an earlier one (so ids are unique within a task).
- A review (the answer) **applies** to a handoff only if it has a `Handoff:` line naming that
  handoff's id (any prefix of 12+ hex digits). A line whose label says
  previous/prior/earlier/old/last is a mention, not a binding. That line is the only required
  field: soft format, hard identity.
- Reviews carry `Verdict: PASS | REPAIR | BLOCKED` (tolerant of layout and case). Answers to
  research, comparison or access requests may be plain text. Only the final `done` state needs a
  PASS; nothing else in the mechanics reads the verdict, and none of it reads the request type.
- The handoff id identifies the *request*, not the source. Source identity (commit + tree, or
  exact file hashes) must be written in the handoff; a moving working tree is never a candidate.
- What the handoff offers (commit + tree, file hashes, "no source change, new evidence X") is
  the worker's responsibility to make unmistakable. Git owns source truth; the reviewer checks
  the actual candidate. If the offered candidate is ambiguous or does not match reality, the
  answer is BLOCKED.

## Whose move (the only state machine)

Computed from the files every time; nothing else is stored:

| Condition | NEXT |
|---|---|
| no published handoff | worker |
| current REVIEW does not name the current HANDOFF | reviewer |
| it names it, verdict PASS, and FINAL_REPORT was written before that handoff was published | done |
| it names it (otherwise) | worker |

Consequences, by construction:

- **A handoff stays due until an applicable review is published.** A reviewer that crashes,
  times out or loses its runner has published nothing, so the handoff is still due and the
  previous REVIEW is untouched. Any later wake-up retries it.
- **Unchanged work stays quiet.** Re-publishing identical bytes is a no-op, and once reviewed, a
  handoff never becomes due again.
- **New material evidence is reviewable** even with the same source: it is new handoff bytes.
- **Stale reviews cannot settle new work**: a review naming an older handoff is refused.
- **Restart needs no recovery step**: any session, watcher or driver re-reads the same answer.

## Publishing

1. Write the complete text to `EXCHANGE/HANDOFF.next.md` or `EXCHANGE/REVIEW.next.md`.
2. Publish (`looper.ps1 publish <folder> handoff|review`), which by hand means:
   - handoff: if identical to the current one, stop. If identical to any *earlier* published
     handoff, refuse: it would inherit that handoffs old answer - a re-sent request must differ
     (say why it is sent again). Otherwise its number is the highest
     `HISTORY/NNN_HANDOFF.md` + 1; write `HISTORY/NNN_HANDOFF.md`, then replace `EXCHANGE/HANDOFF.md`.
   - review: check it names the *current* handoff (else refuse); write
     `HISTORY/NNN_REVIEW.md` (NNN = that handoff's number; add `_2`, `_3` for a second answer),
     then replace `EXCHANGE/REVIEW.md`.
   - "replace" = write a temp file in the same folder and rename it over the target, so a
     reader sees the old or the new file, never half of one.
   - handoff with **attachments** (optional; for files outside Git, such as a document or an
     export): copy each file into `HISTORY/NNN_attachments/` and append to the handoff text a
     list of each file's name, size in bytes and SHA-256, before the checks above. The list is
     part of the handoff's bytes, so a changed file means a new handoff. It names no number, so
     the same text and files stay quiet. The reviewer reviews the snapshots, which cannot change
     or lag behind a sync. `publish ... handoff -Attach <file>,...` does all of this; if anything
     fails, it publishes nothing and leaves no new snapshot. Re-publishing the latest handoff
     (its `EXCHANGE` copy lost) reuses its snapshot only if it holds exactly the same bytes;
     otherwise it refuses and leaves the saved snapshot alone.
3. Only the worker writes handoffs; only the reviewer writes reviews. Both may write TASK.md.

By hand, any shell will do: the id is the first 12 hex digits of `sha256sum HANDOFF.md`
(macOS `shasum -a 256`, PowerShell `Get-FileHash`, Windows `certutil -hashfile <f> SHA256`),
and "replace" is `mv -f` / `Move-Item -Force` from a temp file in the same folder.

Keep task folders on a local disk, not inside a cloud-synced folder (Drive, OneDrive, Dropbox):
sync clients can delay, duplicate or reorder renames and file events.

## Lifecycle: durable record vs disposable runtime

- **Durable record** (keep): `CONTEXT.md`, `PLAN.md`, `TASK.md`, `EXCHANGE/HANDOFF.md`,
  `EXCHANGE/REVIEW.md`, `HISTORY/`, `FINAL_REPORT.md`, `WATCHERS/README.md`, and driver logs
  `WATCHERS/*.log` (one line per attempt - the run's runtime record).
- **Disposable runtime state** (safe to delete whenever no driver is running): everything else in
  `WATCHERS/` (locks, `*.session` ids, last-run output, prompt files, and `WATCHERS/scratch/` for
  an agent's throwaway work), `EXCHANGE/*.next.md` drafts,
  and `.*.tmp` files left by an interrupted publish. Deleting it never changes whose move it is.
  `looper clean <folder>` does exactly this and refuses while a driver holds its lock (`looper.sh`
  checks with `flock(1)`, or the Windows lock itself under Git Bash; elsewhere without `flock` it
  refuses to clean); drivers
  also remove their own session and last-output files, and `WATCHERS/scratch/`, when the task is done.
- **One folder per task.** A new session - after a restart, a deleted chat or a new day - continues
  the existing folder; `new` refuses to create a second one there. For the next task in the same
  project, pick another folder name or finish with this one first.
- **Finishing.** The completed folder *is* the record: keep it, or pack it once and delete it
  (for example `tar -czf <task>.tgz -C <project> .looper`). Looper never creates backup or
  archive copies by itself.

## Wake-ups

Wake-up plumbing only moves attention. It may use file events, polling, hashes, stable reads,
locks and timers; it must not judge work, edit source or create authority. It must: notice due
work already present at start, ignore partial writes, stay quiet on unchanged content, and
leave work due after a failed attempt. `looper.ps1 wait` and `drivers/` implement this.
A heartbeat or wake-up prompt carries no task details - only "you are the <role> for the task
at <folder>; read its CONTEXT.md".

## Invariants

1. The folder is durable state; agent sessions are disposable.
2. Git/source control owns source truth; Looper keeps no second source database.
3. TASK is shared working memory, not authority or candidate identity.
4. PLAN owns the boundary. Changing it is a real decision, noted in TASK.
5. A PASS applies only to the exact candidate and request reviewed.
6. Capability is not permission: Looper grants no merge, deploy, install or external-write authority.
7. Park local blockers and continue; stop the loop only when nothing useful can safely continue.
8. Keep Level 1 boring: complexity must be earned by repeated real friction.
