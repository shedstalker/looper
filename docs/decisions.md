# Decisions

Short records of real design choices. Newest last. Add one when a choice would otherwise be
re-argued by the next session.

**D1 - Settled-ness is derived from files, not stored.** A review applies to a handoff only if
it names that handoff's SHA-256 prefix. Whose move it is gets recomputed every time. *Why:* no
watcher state to lose or corrupt; interrupted reviews cannot consume a handoff; restart needs no
recovery. Proven in the originating project's watcher, generalised here.

**D2 - Handoff id = hash of the handoff bytes.** Not a run number, not the commit SHA. *Why:*
same-source new evidence must be reviewable; byte-identical repeats must stay quiet; non-source
tasks have no commit. HISTORY numbers are for humans.

**D3 - One required labelled line in an answer (`Handoff:`); `Verdict:` for reviews.** *Why:*
soft format, hard identity; the scripts never need to understand the request type (revised
2026-09-27 after user guidance - originally both lines were required).

**D4 - HISTORY is the complete log, written at publish time.** Each publish writes
`HISTORY/NNN_*.md` and then replaces the current file. *Why:* one place to read the whole
exchange in order; numbering is known at publish time. (The earlier spec moved the old file
to HISTORY on replacement; copying at publish is simpler and equally inspectable.)

**D5 - Stale reviews are refused, not published.** *Why:* a late answer to an old handoff must
not overwrite a valid current review or appear to settle new work.

**D6 - The helper comes in two editions that need nothing installed; the contract needs neither.**
`tools/looper.ps1` (Windows PowerShell 5.1 and PowerShell 7) and `tools/looper.sh` (POSIX sh +
awk/grep/sha256sum or shasum). Both are held to identical behaviour by one acceptance suite
(`-Helper ps1|sh`), run on Windows, Git Bash and Linux dash. *Why:* user guidance - the concept
must not be PowerShell-specific; ship the smallest no-install arrangement per platform rather
than forcing one shell everywhere (Python is not installed by default on Windows). The drivers
remain PowerShell: they are an optional convenience. Manual operation remains possible anywhere.

**D7 - Drivers are one generic loop plus thin provider wrappers.** *Why:* the wait/lock/run/retry
logic is provider-neutral; a provider wrapper only needs its command line and touches only
`drivers/<provider>/`. Which wrappers exist is limited by D24.

**D8 - Fresh session per due item for headless roles.** *Why:* sessions are disposable, state is
in files, and fresh contexts avoid compaction drift. Interactive sessions remain supported.
(Superseded for the drivers: they resume by default, D14; `-Session fresh` keeps this option.)

**D9 - The second agent is a general responder, named REVIEWER.** (User steer, 2026-09-27.)
Handoffs may ask for review, research, comparison testing, or access the worker lacks (e.g. a
Google Doc). The verdict words stay PASS/REPAIR/BLOCKED (PASS = done/answered). *Why:* one
exchange shape and one due rule serve all request types; no new message types.

**D10 - Task folder defaults to `<project>/.looper`, excluded via `.git/info/exclude`.** *Why:*
next to the work, easy to find, never committed by accident, no tracked file changed.

**D11 - The skill is generated from canonical files.** `integrations/skill/` holds only the
SKILL.md source and a build script that bundles copies of `template/`, `prompts/` and `tools/`
(later also drivers, the contract and the licence: D21).
*Why:* no second implementation to maintain.

**D12 - `done` needs the final report to predate the handoff that passed.** Found in a live
run: the worker wrote FINAL_REPORT 11 s before publishing its final handoff; during that gap
the old rule ("PASS + report exists") read `done` and the reviewer driver exited, leaving the
final handoff unreviewed. Now the report only counts once a later handoff has passed (file
times, same machine). Editing the report after the final PASS reopens the task. *Why:* keeps
state derived from files, no new marker, and the report is always independently reviewed.

**D13 - Handoff texts are unique within a task.** Found by the dogfood review (Codex, handoff
001): publishing A -> PASS, then B, then A's exact bytes again created handoff 003 that
inherited A's old PASS, and could even reach `done` unreviewed. Publishing now refuses text
identical to any earlier handoff (re-publishing the latest one after a crash is still allowed).
*Why:* keeps identity = content hash with one extra rule, rather than adding numbers or state
to the binding. Regression checks cover it with and without FINAL_REPORT.

## Level 1 Deluxe (v0.2.0; developed as the "L1.1" usability, adapters and dogfood pass)

**D14 - Session resume is the wrappers' default; fresh stays one flag away.** E8: resumed Codex
reviews used roughly a third fewer tokens per follow-up and were a little faster, with the same
verdicts. Only an explicit "cannot resume" from the runtime triggers a cold start (in the same
attempt); an attempt that publishes nothing keeps its session and is retried normally
(user guidance). Session ids live in `WATCHERS/<role>.session`: runtime state, safe to delete.

**D15 - Log requested settings apart from what the runtime reports.** Runtimes refuse or override
requests (an unsupported Claude model was rejected; `--ignore-user-config` turned Codex's sandbox
read-only). Codex reports model/effort/sandbox/tokens; Claude Code reports the model but not effort,
and the log says "(not reported)" rather than repeating the request.

**D16 - Visibility is an adapter concern: interactive self-wait, `-Show`, and attach hints.** No
window management. A visible interactive agent waits on the helper itself; a headless driver can
stream output (`-Show`) and prints `codex resume <id>` / `claude --resume <id>`.

**D17 - Local models go through existing agent runtimes.** Claude Code -> Ollama (64k context)
and OpenCode -> Ollama both completed Looper reviews; Codex `--oss` with the tested Qwen models
could not use Codex's tools. Looper contains no model API or tool loop.

**D18 - Lifecycle: durable record vs disposable runtime; `clean`; one folder per task.** Drivers
remove their own session/last-output files and `WATCHERS/scratch/` at `done`; `clean` removes the rest
(including `WATCHERS/` subfolders) and refuses while a driver runs; `new` refuses to duplicate an
existing task. No automatic backup or archive copies. Dogfooding added `WATCHERS/scratch/`: a
sandboxed reviewer can only write in the task folder, left four throwaway folders there, and was
not allowed to delete them - so throwaway work now has one disposable place.

**D19 - A failed replace publishes nothing.** Found in dogfooding: a sandbox could create files but
not replace `REVIEW.md`. The helpers now remove the history copy they just wrote when the final
replace fails, so nothing half-published remains.

**D20 - The Codex driver re-owns sandbox-created files before each attempt (Windows only).** The
Codex Windows sandbox runs as separate local accounts; its files carry only the grants that existed
when they were written, and a later sandbox identity could not replace `REVIEW.md` (three resumed
attempts failed; re-creating the file as the user fixed it at once). Re-created files keep their
bytes and modified time (the only time Looper reads), so nothing Looper reads changes. The new file is installed with one atomic
rename over the original (MoveFileEx with replace) - review found that an earlier delete-then-move
version could lose a file if interrupted; a failed rename now leaves the original in place (tested).
Lives only in `drivers/codex/` (`reown.ps1`).

**D21 - One generated Skill package for Claude Code, Codex and ChatGPT surfaces that support skill upload (the last not yet exercised).** `SKILL.md`
(open format) plus `agents/openai.yaml` (OpenAI UI metadata), copies of the canonical files, and a
zip for upload. Passes the official Codex `quick_validate.py`. Live: both Claude Code and Codex
bootstrapped a task from "use Looper for this task" with no path given. The build verifies every packaged file
and the zip against the repository, and `-Check` verifies an existing package - added after the final
review found a stale zip (six files older than the source).

**D22 - No Looper settings file (for now).** The choices that recurred in this pass - driver
(provider), role, model, effort, session mode, `-Show`, local model - are each one driver flag;
provider-native config already holds defaults (e.g. Codex's `config.toml` model and effort); the
driver logs what was requested at start-up. To make restarts easy without a settings file, the
worker prompt and the WATCHERS template now ask for the exact launch command to be written in
`WATCHERS/README.md` (added after review found this was only implied). A settings file would
duplicate provider configuration and add precedence rules without a demonstrated gain. Revisit
if people keep retyping long driver commands.

**D23 - Keep the name `REVIEW.md`.** Non-review uses (access, research, local-model and OpenCode
runs) all handled "REVIEW.md = the answer" without confusion; one agent even added a verdict to a
research answer. Renaming would break existing task folders for no observed benefit. The docs call
it "the answer"; the only required line is `Handoff:`.

**D24 - Three runtimes only: Claude Code, Codex CLI, OpenCode (owner, 2026-09-28).** Looper keeps
drivers for these three and no others. A new model or provider (Grok, Gemini, local models, ...)
is reached through OpenCode's own provider support (`-Model provider/model`); if OpenCode cannot
support it cleanly, the limit is documented and nothing is built around it. No driver for other
CLIs, no direct provider API integration. Any other agent can still take a role by hand. *Why:*
the smallest useful tool; OpenCode already gives model breadth behind one driver (E14-E16).
"OpenCode offers this model" is never the same as "this model passed a Looper handoff".

**D25 - A second opinion is a second task folder, not a protocol.** Level 1 keeps one reviewer
and one `REVIEW.md` per folder. For two independent answers on one checkpoint, the worker creates
a second task folder for the same project, publishes the same handoff there, runs both reviewers,
and combines their answers into its next handoff in the main task (E15). *Why:* it worked with no
change to the contract, and a multi-reviewer protocol or queue would add machinery that one
experiment does not justify.

**D26 - Attachments for files outside Git (real use, 2026-09-30).** A worker offering a Drive
document had to hand-write its size and SHA-256 into every handoff, and the reviewer's sandbox
could not read the synced folder; a sync lag would have produced a false "hash differs". Now
`publish ... handoff -Attach` reads each file once, hashes those bytes and snapshots the same
bytes into `HISTORY/<number>_attachments/`, appending a name/size/SHA-256 list to the handoff
text. *Why these details:* the list is part of the handoff's identity, so a changed file is a new
handoff and an old answer cannot settle it. The list names neither the number nor the original
path, so identical text and files stay quiet, and both helpers and all machines produce the same
bytes. A failed publish leaves no new snapshot, and restoring the latest handoff reuses its
snapshot only if it is byte-identical. *Not done:* no attachment verification command (the
listed SHA-256 is enough to check by hand), no folders (zip them), no size limit (the snapshot is
a plain copy). Also from the same use, documentation only: waiting with `wait -For worker`,
session growth, launching a watchable driver, the report's status as a claim, and a host prompt
snippet. A `-NewWindow` option and cumulative token totals in `status` were not added: the logs
already hold the facts, and window management stays outside Looper.
