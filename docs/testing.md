# Testing and acceptance evidence

Two kinds of proof: a deterministic suite with no model calls, and live runs with real,
separate child agents in a disposable test folder. Child agents got only
the task folder, the candidate and their role prompt - never the builder's reasoning or an
expected verdict. Raw artefacts of runs E2-E6 are in `tests/evidence/<run>/`; the dogfood runs
(E7, E12 - Looper reviewing its own development) and later runs are summarised here, and their
raw archives stay in the maintainers' development repository or test area.

Where to look:
- **The deterministic suite:** the next section.
- **E1-E7, the core protocol:** unattended bootstrap, repair, crash and restart, ambiguous
  candidate, access request, no scripts at all, Looper reviewing itself.
- **E8-E13, comfort for real use:** resumed sessions, model and effort, local models, OpenCode,
  skills, real use on another project.
- **E14-E17, the third runtime:** Grok through OpenCode as reviewer and worker, two reviewers on
  one checkpoint, native Windows, a normal install with task folders inside or outside the
  project, and a premature-done race found and fixed.
- **E18, friction from real use:** attachments for files outside Git, and the lessons behind them.
- **E19-E20, Codex as reviewer and builder:** the current model's reviews, and what a sandboxed
  Codex builder can do on Windows.
- **E21, an outside run on Linux:** a driver crash on an unread prompt, and a done rule that
  depended on file times.
- **What is not proven:** the last section.

## Deterministic suite - `tests/acceptance.ps1`

53 checks (27 at v0.1.0 Level 1 Basic; 36 at the first Deluxe checkpoint; 39 at v0.2.0 Level 1 Deluxe; 41 with the OpenCode and Claude Code driver checks; 48 at v0.3.0: six attachment checks, and one from its final review; 50 at v0.3.1, from an outside review; 53 at v0.4.0, after an outside run on Linux: the report hash, the driver's stdin, and a UTF-8 BOM), run against either helper (`-Helper ps1|sh`): bootstrap, git exclude (also in a git worktree),
no-overwrite, template refusal, handoff publish + HISTORY, unchanged handoff quiet, answer
validation (handoff id required, "previous" mention does not bind), soft-format verdicts, a
plain research answer without a verdict, REPAIR -> repair -> re-review, stale review refused (exit 4) with
REVIEW untouched, interrupted reviewer (draft + half temp file) leaves handoff due, restart
notices existing due work, quiet timeout (exit 3), file-event wake-up, ordered HISTORY,
report-before-final-handoff not done early, done (exit 2), done bound by the report's hash (lost write times, an edit after the PASS), driver give-up after N failed
attempts with work still due (exit 5), one driver per role (exit 4), driver detects a
publishing agent, the agent gets its prompt on stdin (one that quits unread is a failed attempt), attachments (snapshot and list, quiet re-send, a failed publish or HISTORY
write leaves nothing, restoring reuses only an identical snapshot), an absolute `-Draft` path (drive letter, spaces),
a Skill build that replaces only a package it generated (the repository, a package holding it,
and either through a junction or symlink, are refused), no references to the
originating project in shipped code, and (PowerShell 7)
the OpenCode and Claude Code drivers pass their settings to the child and leave the caller's
environment untouched.

| Platform (53 checks, measured 2026-09-30 on the v0.4.0 candidate) | `looper.ps1` | `looper.sh` |
|---|---|---|
| Windows 11, PowerShell 7.6.6 | 53 pass | 53 pass (Git Bash has no `flock`; `clean` checks the Windows lock itself) |
| Windows 11, Windows PowerShell 5.1 | 50 pass, 3 skipped (the driver checks need PowerShell 7) | 50 pass, 3 skipped (the same) |
| Linux: PowerShell 7.4.2 in Docker (WSL2), `/bin/sh` = dash | 49 pass, 4 skipped (two Windows-only Codex re-own checks; two git checks, as that image has no git) | 49 pass, 4 skipped (same) |
| The same image with git installed | 51 pass, 2 skipped (the Codex re-own checks) | 51 pass, 2 skipped (same) |

An earlier intermittent failure (twice on Windows PowerShell 5.1, once on Linux pwsh 7.4; only
summary lines survived) was captured on 2026-09-28: the wake-up check, failing on unchanged
`main` in 2 of 4 PS 5.1 runs. It was a real `wait` bug, not a tight test.
`FileSystemWatcher.WaitForChanged` hears only events during the call; the reviewer's draft write
woke the waiter, the publish's rename onto `REVIEW.md` landed during the ~0.5 s rescan and was
lost, and the waiter slept until the next poll (60 s in the check, 30 s by default). PowerShell 7
has the same race with different timing. `looper.ps1 wait` now queues watcher events for its
whole run, so a change during a scan ends the next wait at once; `looper.sh wait` only polls and
was never affected. A focused repro of the check (slow = 10 s or more): old helper 3 of 10 slow
on PS 5.1; fixed helper 0 of 25 on PS 5.1 and 0 of 10 on PS 7, all about 4 s. Full suite after
the fix: PS 5.1 8/8, PS 7 5/5, PS 7 `-Helper sh` 4/4, Linux Docker 5/5 with each helper.

(Inside Codex's sandbox the reviewer ran the suite on PowerShell 5.1, and with `-Helper sh` once the scratch folder was a writable path: pass `-Scratch <writable dir>` there.)

(The suite itself is PowerShell; on Linux it drives `looper.sh` through `sh`. macOS/BSD tools
and busybox are not yet run.)

Linux run, as measured in the table above (the image has no git, so the git-exclude check
skips): copy the repository into `mcr.microsoft.com/powershell:latest` and run
`pwsh -NoProfile -File tests/acceptance.ps1 -Helper ps1` and `-Helper sh` there, for example
`docker run --rm -v <repo>:/src:ro mcr.microsoft.com/powershell:latest sh -c "mkdir /tmp/l && cd /src && tar --exclude=./.looper -cf - . | tar -xf - -C /tmp/l && cd /tmp/l && pwsh -NoProfile -File tests/acceptance.ps1 -Helper sh"`
(leaving out a live `.looper/` task folder, whose sandbox-owned lock file cannot be copied).
Earlier runs installed git first (`apt-get update && apt-get install -y git`), which lets that
check run as well.

## Live runs

Models: Claude Code 2.1.278 (`claude-opus-5`), codex-cli 0.158.0-alpha.2 (`gpt-6-sol`).
Launch commands are exactly what the drivers log in `WATCHERS/<role>.log` and are documented
in `drivers/*/README.md`.

| # | Scenario | Worker | Reviewer | Result |
|---|---|---|---|---|
| E1 | **Bootstrap + PASS, unattended.** User-style 3-line prompt; worker creates task folder, PLAN, TASK, commit, FINAL_REPORT, handoff; reviewer checks git blobs/tree; both drivers stop at `done` | `claude -p` (bootstrap), then Claude worker driver | Codex driver | **PASS.** No human relay. ~5 min, bootstrap $1.07. Became `examples/hello-looper`. |
| E2a | **Interrupted reviewer.** Codex review killed after 25 s (driver + 3 child processes) | - | Codex driver | **Handoff stayed due, REVIEW untouched.** |
| E2b | **Reviewer restart + worker cold start.** Driver restarted on the still-due handoff; a fresh worker session continued from files | Claude worker driver | Codex driver | Reviewer found and reviewed handoff 001 (PASS for the checkpoint, correctly noting the changelog item still open); fresh worker added the changelog, wrote FINAL_REPORT, published 002. |
| E2c | **Found defect: premature `done`.** Worker wrote FINAL_REPORT 11 s before its final handoff; the old rule read `done` and the reviewer driver exited | | | Fixed (decision D12) + regression check; restarted reviewer passed 002; task done. |
| E3 | **REPAIR with a real bug; Codex worker + Claude reviewer.** Planted off-by-one (prints 9, not 15) | Codex worker driver | Claude reviewer driver | Claude **REPAIR**: ran both PLAN proofs in a scratch copy, found a second edge case, gave a fix. Codex fixed the code but **could not commit** (sandbox keeps `.git` read-only), so it sent an *access* request instead of offering a moving tree. Claude answered **BLOCKED** with a diagnosis and three unblock options, and refused to commit itself. The worker driver retried, found nothing new, logged it (1/3). The human took option 3 (committed the worker's change, noted it in TASK); the next fresh Codex session read that note, wrote FINAL_REPORT and asked for the final review; Claude **PASS**; both drivers stopped at `done`. |
| E4 | **Ambiguous candidate.** Handoff names a non-existent commit/tree (real HEAD is fine) | hand-made | Codex, `-Once` | **BLOCKED**: "different candidate from the one offered, so I cannot give that candidate a PASS". |
| E5 | **Non-review request (access).** Worker asks the reviewer to read a file it cannot reach | hand-made | Claude, `-Once`, extra `--add-dir` | **PASS** with threshold, units and a SHA-256 matching `sha256sum`; also flagged a mangled path in the handoff (a test-harness quoting slip). |
| E6 | **No scripts at all.** Looper copy with `tools/` and `drivers/` deleted; worker told to follow `docs/contract.md` by hand; reviewer given only the one-line prompt | `claude -p` (Bash allowed) | `codex exec` once | Worker created the folder, PLAN, TASK, commit, HISTORY/001 and the handoff by hand; reviewer published PASS with a correct handoff id by hand. **Both real helpers read the result as `done`.** Worker parked one item honestly (its permissions blocked `.git/info/exclude`) and committed by explicit path instead. |
| E7 | **Dogfood: Looper reviews Looper.** This build session as interactive worker (background `looper.ps1 wait` woke it), Codex driver as reviewer on the repo | the building Claude Code session | Codex driver | 001 **REPAIR**: found a real replay bug (identical earlier handoff text inherited an old PASS, even to `done`) that no test covered, and a provider name in the template. Fixed (D13) + regression checks confirmed failing on old code. 002 **PASS** after the reviewer re-exercised both helpers. Same driver picked up later handoffs without relaunch. 003, 005 and 006 **REPAIR** on report/doc accuracy only; 004 superseded; 007 final **PASS** (all 27 checks re-run by the reviewer). Full exchange archived after the tag. |

## Live runs, pass 2 - Level 1 Deluxe, v0.2.0 (the "L1.1" pass: sessions, model/effort, visibility, local models)

Runtimes: codex-cli 0.158.0-alpha.2, Claude Code 2.1.278, Ollama 0.34.0 on an RTX 3090 (24 GB).
Raw logs stay in the test area; the driver log lines quoted here are verbatim.

**Runtime facts established by direct tests (before any driver code):**
- Codex `exec resume <id>` keeps the conversation (it recalled a word from the earlier turn) but
  **not the sandbox**: the resumed run came back `read-only` with the working directory taken
  from the launching process. Passing `-c sandbox_mode=workspace-write` restores it. There is no
  `--sandbox`/`--cd` on `exec resume`. An unknown id fails explicitly: exit 1,
  `thread/resume failed: no rollout found`.
- Codex prints the model, provider, sandbox, reasoning effort and session id it actually used in
  its header, per run; `-m` and `-c model_reasoning_effort=...` are honoured per call, including
  on resume. `tokens used` is cumulative for a resumed session.
- Claude Code `-p --resume <id>` keeps the conversation under the same session id and allows a
  different `--model`; the working directory follows the process. An unknown id fails explicitly:
  exit 1, `No conversation found with session ID`. JSON output reports the models used, **not the
  effort level**. Requesting `claude-opus-5-5` on 2.1.278 was refused ("version 2.1.280 or newer
  is required") - a requested setting that was not honoured.

| # | Scenario | Result |
|---|---|---|
| E8 | **Fresh vs resumed reviewer, same work.** Two identical repos, three review rounds each (planted even-length-median bug, then an overflow the reviewers found, then an underflow they found). Codex driver, requested `gpt-6-sol`/`high`, `-Session fresh` vs `resume`; runtime reported `gpt-6-sol`/`high` every time. | Same verdicts each round (REPAIR, REPAIR, REPAIR with the same findings). Wall time fresh 57 / 123 / 82 s, resumed 69 (cold start) / 85 / 67 s. Tokens fresh 23.2k / 17.9k / 14.7k; resumed per round (inferred from cumulative 12.1k / 23.8k / 32.2k) 12.1k / 11.6k / 8.5k. Two identical fresh first rounds differed 23.2k vs 12.1k, so treat this as indicative, not precise. Conclusion: resume is cheaper and a little faster with no visible loss of review quality; it became the default, with `-Session fresh` kept. |
| E8b | **Claude resume via the driver.** Two research handoffs, `claude-sonnet-5`/`low`, `-Session resume`. | Handoff 002 ran `resume 2ef16f2b...` (same id); the agent said it remembered the earlier answer without reading HISTORY. Log: `runtime reported: model=claude-sonnet-5 effort=(not reported)`. The driver printed `open this session: claude --resume 2ef16f2b...`. |
| E8c | **Resume fallback and hygiene (no model).** Acceptance checks with a fake agent: saved session reused; explicit "no rollout found" -> cold start in the same attempt and the handoff settled; a resumed attempt that publishes nothing keeps its session; deleting all session state still recovers; `clean` removes runtime files, keeps the record, refuses while a driver holds its lock (PowerShell, and `sh` with flock on Linux; since v0.3.0 also Git Bash, see E19). Mutation check: breaking the fallback made two checks fail. | Pass on Windows PS 7.6 / 5.1, Git Bash sh, Ubuntu pwsh + dash. |
| E9a | **Codex + local Qwen** (`codex exec --oss --local-provider ollama`), review of a planted off-by-one. qwen3.8:27b, then qwen3.6:27b, then qwen3.6 with `--ignore-user-config`. | **Failed safely, three times** - nothing published, handoff stayed due. qwen3.8: `unsupported call: read_file`, then Ollama `no user query found in messages`. qwen3.6: ran a web search and a Todoist app from the user's Codex config instead of reading the files. With the user config ignored: `unsupported call: read_file` again, and the runtime reported `sandbox=read-only` although `workspace-write` was requested. |
| E9b | **Claude Code + local Qwen** (Ollama's Anthropic-compatible API). At Ollama's default 32k context the request was lost (`no user query found` / "I'm ready. What would you like to work on?"). With a 64k-context model alias it worked. | qwen3.6-64k: correct **REPAIR** (prints 9, not 15; right root cause) in 3 min (session `8eb598f7...`). On the fixed commit, the next run started a fresh session (`5d3cd04e...`) and published nothing - the allow-list defect in E9c; after the fix, a run **resumed `5d3cd04e...`** and published a correct **PASS** in 1 min. qwen3.8-64k: correct REPAIR, verified commit/tree and ran the script, 4.3 min. An unconstrained probe earlier gave a wrong answer (claimed 15 and invented a fourth number), so local review is plausible but not yet trustworthy on its own. |
| E9c | **Driver defect found by the local run.** The Claude reviewer's allow-list only had `Bash(pwsh *)`; Qwen used Claude Code's separate PowerShell tool (as the prompts recommend) and `sh looper.sh`, both denied. It then correctly refused to guess the handoff id and published nothing. | Fixed: allow-list now includes `PowerShell` and `Bash(sh *)` (a `PowerShell(& ...)` pattern rule did not match in tests; the whole tool is no wider than `Bash(pwsh *)`). The next run published. |
| E9d | **Visible headless (`-Show`).** Codex driver run with `-Show`. | Codex's progress streamed live into the driver's terminal while still being logged. |
| E10 | **OpenCode + local Qwen** (a third runtime). OpenCode 1.18.32 installed in a throwaway Linux container; `opencode run --dir <task> -m ollama/<qwen3.6 64k> --auto --format json "<one-line reviewer prompt>"` against the host's Ollama; Looper repo mounted read-only. | Correct **REPAIR** (ran the script: 9 vs 15; right root cause), published through the helper with the right handoff id, in **70 s**. JSON events carry the session id but not the model. |
| E11 | **Skills reduce setup.** Generated skill installed per project (`.claude/skills/looper`, `.agents/skills/looper`); each agent told only "Use Looper for this task: ...", no Looper path. Official Codex `quick_validate.py` run on the package. | Validator: "Skill is valid!". Claude Code (29 turns, $1.07 - about the same as E1's path-given bootstrap) and Codex (2.5 min) each located the skill, used it as the Looper home, created the task and published handoff 001. Codex's sandbox blocked commits and it **invented a substitute repository** (`.looper/commit.git`) instead of asking; the worker prompt now says to record a blocked need and ask, not substitute. |
| E12 | **Dogfood, this pass** (worker: this Claude Code session; reviewer: Codex driver, requested and reported `gpt-6-sol`/`high`, `-Session resume -Show`). | Checkpoint A: 001 **REPAIR** - two evidence claims corrected (check count; the exact Qwen session sequence, which I had overstated). 002: the **resumed** reviewer finished the recheck but could not replace `EXCHANGE/REVIEW.md` ("access denied"); the helper's new failed-replace rule published nothing; three attempts, then the driver **gave up (exit 5)** with the handoff still due - every invariant held. Cause: the file was owned by a Codex sandbox account and lacked the grant of the later sandbox identity (a controlled resume test elsewhere did not reproduce it). Re-creating the file as the user, same bytes and time, let the **same resumed session** publish its **PASS** in 26 s. The Codex driver now does this re-ownership before each attempt (D20). Later exchanges: 003 REPAIR (a check that never ran, a non-atomic re-own, incomplete redaction), 004 PASS, 005 REPAIR (stale skill zip), 006 final **PASS**; the reviewer's throwaway folders led to `WATCHERS/scratch/`. Side note: my first attempt to repair permissions with `icacls /reset` also removed the sandbox's grants from the task folder; Codex restored them on its next run. |
| E13 | **Real use outside Looper's own development.** Another working session used Looper (a clone at the v0.2.1 tag; helper, drivers and prompts identical to the development versions at the time of E13) on a separate private project, with Codex reviewers via `drivers/codex/run.ps1`. Model and effort were not requested; Codex reported `gpt-6-sol`/`high` from the user's own Codex configuration. Five task folders inspected read-only, metrics only. | **Three loops ran concurrently** (drivers started in the same second; separate task folders and locks) and each research request was answered PASS in 4.5-6.5 min with no interference. One review loop went REPAIR, REPAIR, REPAIR, PASS and reached `done` with a final report in about 7 min on a resumed session. One loop was still mid-task after a REPAIR. Across 8 attempts: none unpublished, no resume fallbacks, no give-ups. Four of the five drivers were deliberately run with `-Session fresh`. Leftovers were lock files and one `WATCHERS/scratch` folder - disposable runtime state that `clean` removes. |

### Platform findings from live runs (each fixed or documented)

- Codex on Windows: its sandbox refuses to spawn the WindowsApps `pwsh.exe` ("Access is denied").
  The reviewer worked around it by following the manual protocol. Fix: prompts now call the
  helper in-process (`& looper.ps1 ...`), and the helper runs on Windows PowerShell 5.1 too.
- PowerShell passes `$null` to .NET as `""`: `File.Replace(tmp, target, $null)` failed. Fixed with `[NullString]::Value`.
- `pwsh -File` cannot pass string arrays and treats values starting with `-` as parameter
  names. Driver `-Extra` is now one string, passed as `-Extra:"--flag value"`.
- Codex `workspace-write` keeps `.git` read-only; `--add-dir <repo>/.git` is refused on Windows.
  A sandboxed Codex worker cannot commit. Documented; `-Sandbox` option added (user's choice).

## Live runs, pass 3 - Grok through OpenCode, and a second opinion

Runtimes:
- OpenCode 1.18.32, both in a Linux container (`node:22-slim`) and natively on Windows (the
  official `opencode-windows-x64.zip`, digest checked);
- Grok requested as `xai/grok-4.7` through a SuperGrok subscription (OpenCode's device-code
  sign-in; no API key, no API credits);
- codex-cli 0.158 (`gpt-6-sol`, high).

The helper and prompts were those of v0.2.1. Test projects were disposable. Every run used
explicit permission rules and never `--auto`. OpenCode records the model it requested; the model
that actually answered is not reported.

| # | Scenario | Result |
|---|---|---|
| E14 | **Grok via OpenCode, in a container.** Only the project, a read-only v0.2.1 copy and the sign-in volume were mounted. Allow-list: read tools; edits limited to the reviewer's files; the helper, read-only git and `node`. **Reviewer:** a `slugify` task with two planted defects. **Worker:** Grok given only the README's one-line worker prompt; I (Claude Code) reviewed. | **Reviewer:** 001 **REPAIR** in 88 s. It found both defects plus a third (cut not at a word boundary) and missing test coverage, and ran its own probe in `WATCHERS/scratch/`. 002 **PASS** in 114 s on the resumed session. A wake-up with nothing due took 7 s and changed nothing ("Nothing due: NEXT is worker"). Final review in a **fresh** session: **REPAIR** in 266 s. It was right: my FINAL_REPORT named the `.gitignore` commit as the first version. 004 **PASS** in 69 s, then `done`. **Worker:** Grok created the task with the helper, wrote PLAN and TASK, code and tests, committed, and published a handoff naming the exact commit and tree, in 140 s. My REPAIR (a missing or `NaN` width silently wrapped every word) was fixed in 48 s; Grok also clarified PLAN and noted why in TASK. Final report and handoff took 31 s, then final **PASS** and `done`. Each run used 63k-434k tokens, mostly cached input. |
| E15 | **Two reviewers, one checkpoint.** A `parseDuration` candidate with an unanchored regex. The main task (`<project>/.looper`) went to Codex. A second task folder outside the project (its own `new`, the same PLAN, a byte-identical handoff with the same id) went to Grok in a container, with the project read-only and Codex's folder unreadable. Both started together. | Both returned **REPAIR**. Codex took 92 s and 42k tokens; it had no Node on the host, so it derived values from the code. Grok took 98 s and about 200k tokens, and ran probes. Both caught all five failing PLAN error cases. Codex added one extra input; Grok added 13 more of the same defect, including a case-sensitivity input. No false positives, no disagreement. Neither log shows any access to the other's folder. The worker combined both into one repair in the main task, and Codex returned **PASS** (203 s; it found VS Code's bundled Node and ran the tests). Grok's edit rules had been written as absolute paths for a folder outside the project and did not match, so its edits were refused. **It then wrote its answer through a shell command the allow-list permitted** and published correctly. |
| E16 | **Native Windows, no container.** OpenCode's data, config and credential were kept in a test folder via `XDG_*`, with a second device-code sign-in. A PowerShell `Get-Initials` task, first through the generic driver, then through the new `drivers/opencode/run.ps1`. | Generic driver: 001 **REPAIR** in 121 s (ran `test.ps1` and its own probe; all four spec failures). OpenCode's shell on Windows was Git Bash. Five command forms outside the allow-list were refused and retried in allowed forms; every write went through the edit tool into allowed paths. 002 **PASS** in 78 s, resumed. The new wrapper, with only its injected rules: final 003 **PASS** in 63 s, resumed, then `done`. **Guardrail probe:** asked to append to the source through the edit tool, Grok was refused, the file stayed unchanged, and it stopped. A missing session makes OpenCode print `Session not found` (exit 1), the driver's cold-start signal. |

Findings from this pass:
- `opencode run` refuses anything configured as "ask", since nobody is there to approve it.
  Rules must be explicit allow/deny, and paths outside the project (the Looper home) must be
  allowed, because `external_directory` defaults to "ask".
- OpenCode matches edit rules against the path relative to its working folder's git root, or to
  the filesystem root when that folder is in no repository. The driver now writes each rule as
  the task folder's exact path in every such form, so any layout works (E17).
- OpenCode permission rules are guardrails, not a sandbox (E15). The driver's README says so;
  a container or VM is the hard boundary.
- OpenCode's JSON `cost` field is a price-list estimate, not the subscription's charge.
- Independent review of the driver (Codex, 001 REPAIR) found that run in-process it left
  `OPENCODE_PERMISSION` set in the caller's session, so a later `-Permission own` run inherited
  the guardrails. It also found that a task folder outside the project was accepted with rules
  that could not match. Both fixed, with a model-free acceptance check that uses a fake
  `opencode`. On Windows, a task created by the sh helper under Git Bash records POSIX paths
  that PowerShell drivers cannot use; the OpenCode driver now says so.
- The Claude Code driver's `-Local` had the same leak (ANTHROPIC_* left pointing at Ollama in
  the caller's session); fixed, with a model-free check.
- The Codex driver passed `-Extra` to `codex exec resume`, which rejects `--add-dir` (the form
  the Codex README suggested) and `--oss` (used by `-Local`), so every resumed attempt failed at
  once. The work stayed due and the driver gave up after three tries. `-Extra` is now documented
  as `-c` settings, and `-Local` always starts fresh. Live check with a disposable task: a
  reviewer with `-Extra:"-c sandbox_workspace_write.writable_roots=[...]"` wrote its marker
  file into the extra folder on a fresh run and on two resumed runs (all PASS).
- The helper printed `NEXT: worker` after every published review, even one that finished the
  task. It now prints the recomputed next move (`done` after a final PASS).
- Usefulness of a second opinion: the parallel run cost about 1.5 minutes of wall time and added
  confidence and extra test inputs. It found no defect the first reviewer missed. Worth it for
  consequential checkpoints; not needed routinely.

### E17 - a normal install, both layouts, and a race (2026-09-28)

| # | Scenario | Result |
|---|---|---|
| E17a | **Normal install.** OpenCode 1.18.32 unpacked to `%LOCALAPPDATA%\Programs\opencode` and put on the user PATH, signed in once (SuperGrok device code). The driver found `opencode` on PATH in a fresh session, with no `-OpenCode` and no test settings. `Get-Median` task with a planted even-count bug. | 001 **REPAIR** in 83 s (the right bug, plus incomplete tests). 002 **REPAIR** in 82 s, resumed: a real bug in the worker's fix - `-not $Values` rejected `Get-Median 0`, because PowerShell treats `@(0)` as false. 003 **PASS** in 58 s. No blocked tool calls. |
| E17b | **Task folder outside the project** (like a separate `looper-tasks` directory; not in any git repository), project path with a space. First try: the reviewer's own writes into its task folder were refused, because OpenCode matches edit rules relative to its git root, not the working folder; Grok wrote them through the shell instead. | Driver changed: the reviewer runs in the task folder. Rules were first anchored on the task folder's *name*; review found that `*median-task/...` also matched `othermedian-task` and any same-named folder in the repository. Final rules name the task folder's **exact path** in each form OpenCode may use (git-relative, root-relative, absolute; either slash). **Full loops to `done` with Grok in both roles**: REPAIR, then the worker fixed, committed and handed off, PASS, then the final report and final PASS. Name-anchored rules: both layouts, 8 runs. Exact rules: the outside layout, 5 runs. **Zero blocked tool calls in all 13.** Every write went through the edit tool to the right folder; the reviewer never touched the source. **Probes with real OpenCode and Grok, exact rules:** the reviewer could not edit a look-alike `othermedian-task\TASK.md` (not even read it: outside its allowed folders); could read but not edit another `.looper\TASK.md` inside the same project; could not edit project source; could edit its own `TASK.md`. The worker could not write the reviewer's `REVIEW.md` but could edit source. |
| E17c | **Premature `done` race.** In real use, a Codex reviewer driver exited as "done" 0.7 s after the report was written and before the final handoff's review. `status` had read `HANDOFF.md` (the PASSed handoff) just before a publish replaced it, then looked up the *new* file's write time for the done rule. The faster event-driven `wait` made the window easy to hit. | Repro (status polled while the worker writes the report and publishes the final handoff): `looper.ps1` 11 of 12 rounds showed a premature `done`, `looper.sh` 8 of 8. Fix: each file's write time is taken together with its content (ps1: unchanged across the two stable reads; sh: `cp -p` snapshots). After: 0 of 12 and 0 of 8. |

### E18 - friction from real use: files outside Git (2026-09-29/30)

Real use on another project gave the first friction list the plan waited for:
- a builder running four private Codex review rounds;
- a plan review of a Google Drive document that ran to four rounds.

Findings:
- A review could not be tied to a file outside Git without hand-writing its size and SHA-256.
- The Codex sandbox could not read the synced Drive folder. It fell back to a Drive connector, so
  a sync lag would have produced a false "hash differs".
- Waiting meant parsing driver logs.
- The report's status wording ("SATISFIED if it passes") was premature.
- A resumed reviewer used 105k, 135k, then 161k tokens over three rounds.
- The host system's builder only used Looper once it was told to.

| # | Scenario | Result |
|---|---|---|
| E18a | **Attachments, model-free.** `publish ... handoff -Attach` with two files (one with a space in its name), both helpers. | Snapshots in `HISTORY/001_attachments/` are byte-identical to the files; the handoff lists name, size and SHA-256. Re-sending the same text and files is quiet (`unchanged`); an edited file makes handoff 002 with its own snapshot. Reverting to the first file is refused as a replay of 001. A missing file, or a failed publish (unreplaceable `HANDOFF.md`), leaves no handoff and no snapshot. The same draft and files give byte-identical handoffs from `looper.ps1` and `looper.sh`, so a re-send from the other edition is `unchanged`. Three acceptance checks at first; six after the repairs in E19. |
| E18b | **Live: a Drive file, a Codex reviewer that cannot reach Drive.** The worker attached a `PLAN.md` straight from the synced Google Drive folder; the Codex driver (`gpt-6-sol`, high, fresh) reviewed it. | **PASS** in 71 s. The reviewer verified the snapshot's SHA-256 with `certutil` and checked its content. Its attempt to read the original on the synced drive failed ("access denied", then "path not found"): the reach problem is real, and the snapshot makes it irrelevant. |
| E19 | **Current Codex model, review of the attachments change.** Codex CLI 0.159 (0.158 rejected the model), driver requested defaults from the user's config; runtime reported `gpt-6.1-sol`/`high` each time; fresh for 001, resumed after. | 001 **REPAIR** (a failed HISTORY write left the snapshot and blocked a retry; restoring the latest handoff used the wrong folder number), 79k tokens, 6 min. 002 **REPAIR** (the `sh` restoration comparison skipped names starting with `..`, found by the reviewer's own probe), 105k tokens, 4.5 min. 003 **PASS**; the reviewer re-ran its six tampered-snapshot probes and the 47-check suite with `looper.sh` on PowerShell 5.1 (002 had run the then-46-check suite with both helpers). Each repair added checks (44 to 47). 004 (final review, fresh, `xhigh`) **REPAIR**: two older `sh` bugs outside attachments - `clean` without `flock(1)` (Git Bash) deleted runtime files while a driver held its lock, and an absolute Windows `-Draft` path was treated as relative. Both fixed; one new check and one strengthened (48). |
| E20 | **What a Codex builder can do on Windows** (from real use: a Codex worker in another project could not commit or prove on PowerShell 7). Probed with `codex sandbox -- <command>` (codex-cli 0.159, `workspace-write`, no model), in throwaway folders; transcripts kept with the review task. | Editing files and PowerShell 5.1 work. `git commit` in the existing repository is refused (`.git/index.lock: Permission denied`), also with its `.git` in `writable_roots`; the reviewer showed that a new repository it creates in writable scratch can commit. The Store PowerShell 7 cannot start (Windows error 5). The official 7.6.6 zip (signature checked), unpacked in a scratch folder Codex had granted, started, and Looper's suite gave 50 passed on it inside the sandbox; with the sandboxed 5.1 it gave 46 passed and 4 skipped (the two PowerShell 7 driver checks, and two re-own checks without `Get-Acl`). Installed to `C:\Tools\PowerShell\7`, the same zip started in the sandbox (this probe records a launch only; the 50-pass result above used the granted scratch folder). The reviewer later ran the suite with that installed executable from its `WATCHERS\scratch`: 48 passed and 2 failed, the two re-own checks, whose fixture skips paths containing `WATCHERS` - a test-location limit, not a sandbox one. Under `%LOCALAPPDATA%\Programs` it could not start, nor could OpenCode, Ollama or Docker Desktop's `docker.exe` there: the sandbox runs as `CodexSandboxUsers` accounts, granted `~\.local\bin` and `AppData` but not `AppData\Local\Programs` on this machine. Git (read), Git Bash `sh` by full path and `gh --version` started. Network is off by default; with `network_access=true`, Ollama's `localhost` API answered but one HTTPS request to github.com failed (`SEC_E_NO_CREDENTIALS`). `wsl -l -q` is refused; a Docker daemon was not tested. `taskkill.exe` is refused even for the sandbox's own children; `Stop-Process` stops them. A patch-based hand-over was tried and dropped: `git add -N` needs to write to `.git`, and committing in the same clone is simpler. Docs: the Codex driver README. |
| E21 | **An outside run of the public v0.3.1 on Linux** (another user's Claude session, no signed-in agent CLIs; the suite with both helpers and `status` on the bundled example), then follow-up here. | Suite 48 passed / 2 Windows-only skips, but two findings, both reproduced here. (1) The Claude Code `-Local` driver check failed with "Broken pipe" in 6 of 7 runs: on Linux/macOS `Start-Process` copies the prompt through a pipe, and an agent that exits without reading it made the driver throw instead of counting a failed attempt (here 1 in 40 through the old driver in Docker, 0 in 40 after the fix; `sh` now opens the prompt file). (2) `status` on the example said `NEXT: worker` after a clone (here 1 of 3 fresh clones): the done rule compared write times, which git does not keep. Now the report is bound by hash (D27); the example was re-recorded with a real run (fresh `claude -p` worker, Codex reviewer PASS in about 3 min, the reviewer checked the report hash itself) and shows `done` even with the report's time moved to 2030. Found on the way: a one-shot `claude -p` worker started a reviewer driver in the background, which died with its session after "attempt start"; the handoff stayed due and the next driver answered it (worker prompt updated). Also: the re-own checks failed when the suite's scratch sat under a task folder's `WATCHERS` (found by a reviewer); re-own now judges paths inside the task folder. The final review of the fix (Codex, xhigh) found that `looper.sh` missed a report binding, or a verdict, on a first line behind a UTF-8 BOM: an edited report could show `done` in `sh` only. Both `sh` parsers now skip one leading BOM, as `looper.ps1` does; a check covers status and cross-edition publishing. |

The other findings were answered in the docs (D26): the worker prompt's waiting pattern, the
report status as a claim, when to use a fresh session, launching a watchable driver, and
`integrations/host-snippet.md`.

## Not proven / limits

- Multi-hour runs: the longest loops are well under an hour (including the real-use loops in E13). Nothing in the design depends on
  duration, but a long real task is still the missing proof.
- macOS/BSD tools and busybox have not been run (Linux dash and Git Bash sh have).
- OpenCode: tested with Grok (`xai/grok-4.7` only; small tasks) and once with local Qwen. Other providers it offers (Gemini, ...) are untested with Looper; macOS is untested. The OpenCode driver was run natively on Windows only; the container runs used the command line directly.
- Local models: 4 of 4 Looper review runs through Claude Code or OpenCode were correct once the
  context window was large enough, but an unconstrained probe gave a wrong answer; not yet
  trusted as the only reviewer of consequential work. Codex + the tested Qwen models did not work.
- The Codex Windows sandbox permission problem (E12) was diagnosed and mitigated but could not be
  reproduced on demand, so the exact trigger is unknown.
- Skills were checked with Claude Code and Codex CLIs and the official Codex validator; the ChatGPT
  desktop app's upload path was not exercised.
