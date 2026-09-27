# Testing and acceptance evidence

Two kinds of proof: a deterministic suite with no model calls, and live runs with real,
separate child agents in a disposable test folder. Child agents got only
the task folder, the candidate and their role prompt - never the builder's reasoning or an
expected verdict. Raw artefacts of runs E2-E6 are in `tests/evidence/<run>/`; the dogfood runs
(E7, E12 - Looper reviewing its own development) are summarised here, and their raw archives stay
in the maintainers' development repository.

## Deterministic suite - `tests/acceptance.ps1`

39 checks (27 at v0.1.0 Level 1 Basic; 36 at the first Deluxe checkpoint; 39 at v0.2.0 Level 1 Deluxe), run against either helper (`-Helper ps1|sh`): bootstrap, git exclude,
no-overwrite, template refusal, handoff publish + HISTORY, unchanged handoff quiet, answer
validation (handoff id required, "previous" mention does not bind), soft-format verdicts, a
plain research answer without a verdict, REPAIR -> repair -> re-review, stale review refused (exit 4) with
REVIEW untouched, interrupted reviewer (draft + half temp file) leaves handoff due, restart
notices existing due work, quiet timeout (exit 3), file-event wake-up, ordered HISTORY,
report-before-final-handoff not done early, done (exit 2), driver give-up after N failed
attempts with work still due (exit 5), one driver per role (exit 4), driver detects a
publishing agent, no references to the originating project in shipped code.

| Platform | `looper.ps1` | `looper.sh` |
|---|---|---|
| Windows 11, PowerShell 7.6.6 | all pass | all pass (Git Bash `sh`) |
| Windows 11, Windows PowerShell 5.1 | all pass | - |
| Linux: Ubuntu 22.04 in Docker (WSL2), PowerShell 7.4.2, git 2.34, `/bin/sh` = dash | all pass | all pass |

The suite has an intermittent failure that has not been captured: twice on Windows PowerShell 5.1 (once in eight runs, once in seven) and once on Linux pwsh 7.4 (followed by twelve clean Linux runs), each time passing on immediate reruns; only the summary line survived (the timing-based wake-up check is the likely candidate).

(Inside Codex's sandbox the reviewer ran the suite on PowerShell 5.1, and with `-Helper sh` once the scratch folder was a writable path: pass `-Scratch <writable dir>` there.)

(The suite itself is PowerShell; on Linux it drives `looper.sh` through `sh`. macOS/BSD tools
and busybox are not yet run.)

Linux run: `docker run --rm -v <repo>:/looper:ro mcr.microsoft.com/powershell:latest
bash -c "apt-get install -y git; pwsh -File /looper/tests/acceptance.ps1 -Helper sh"` (and without `-Helper`).

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
| E8c | **Resume fallback and hygiene (no model).** Acceptance checks with a fake agent: saved session reused; explicit "no rollout found" -> cold start in the same attempt and the handoff settled; a resumed attempt that publishes nothing keeps its session; deleting all session state still recovers; `clean` removes runtime files, keeps the record, refuses while a driver holds its lock (PowerShell, and `sh` with flock on Linux). Mutation check: breaking the fallback made two checks fail. | Pass on Windows PS 7.6 / 5.1, Git Bash sh, Ubuntu pwsh + dash. |
| E9a | **Codex + local Qwen** (`codex exec --oss --local-provider ollama`), review of a planted off-by-one. qwen3.8:27b, then qwen3.6:27b, then qwen3.6 with `--ignore-user-config`. | **Failed safely, three times** - nothing published, handoff stayed due. qwen3.8: `unsupported call: read_file`, then Ollama `no user query found in messages`. qwen3.6: ran a web search and a Todoist app from the user's Codex config instead of reading the files. With the user config ignored: `unsupported call: read_file` again, and the runtime reported `sandbox=read-only` although `workspace-write` was requested. |
| E9b | **Claude Code + local Qwen** (Ollama's Anthropic-compatible API). At Ollama's default 32k context the request was lost (`no user query found` / "I'm ready. What would you like to work on?"). With a 64k-context model alias it worked. | qwen3.6-64k: correct **REPAIR** (prints 9, not 15; right root cause) in 3 min (session `8eb598f7...`). On the fixed commit, the next run started a fresh session (`5d3cd04e...`) and published nothing - the allow-list defect in E9c; after the fix, a run **resumed `5d3cd04e...`** and published a correct **PASS** in 1 min. qwen3.8-64k: correct REPAIR, verified commit/tree and ran the script, 4.3 min. An unconstrained probe earlier gave a wrong answer (claimed 15 and invented a fourth number), so local review is plausible but not yet trustworthy on its own. |
| E9c | **Driver defect found by the local run.** The Claude reviewer's allow-list only had `Bash(pwsh *)`; Qwen used Claude Code's separate PowerShell tool (as the prompts recommend) and `sh looper.sh`, both denied. It then correctly refused to guess the handoff id and published nothing. | Fixed: allow-list now includes `PowerShell` and `Bash(sh *)` (a `PowerShell(& ...)` pattern rule did not match in tests; the whole tool is no wider than `Bash(pwsh *)`). The next run published. |
| E9d | **Visible headless (`-Show`).** Codex driver run with `-Show`. | Codex's progress streamed live into the driver's terminal while still being logged. |
| E10 | **OpenCode + local Qwen** (a third runtime). OpenCode 1.18.32 installed in a throwaway Linux container; `opencode run --dir <task> -m ollama/<qwen3.6 64k> --auto --format json "<one-line reviewer prompt>"` against the host's Ollama; Looper repo mounted read-only. | Correct **REPAIR** (ran the script: 9 vs 15; right root cause), published through the helper with the right handoff id, in **70 s**. JSON events carry the session id but not the model. |
| E11 | **Skills reduce setup.** Generated skill installed per project (`.claude/skills/looper`, `.agents/skills/looper`); each agent told only "Use Looper for this task: ...", no Looper path. Official Codex `quick_validate.py` run on the package. | Validator: "Skill is valid!". Claude Code (29 turns, $1.07 - about the same as E1's path-given bootstrap) and Codex (2.5 min) each located the skill, used it as the Looper home, created the task and published handoff 001. Codex's sandbox blocked commits and it **invented a substitute repository** (`.looper/commit.git`) instead of asking; the worker prompt now says to record a blocked need and ask, not substitute. |
| E12 | **Dogfood, this pass** (worker: this Claude Code session; reviewer: Codex driver, requested and reported `gpt-6-sol`/`high`, `-Session resume -Show`). | Checkpoint A: 001 **REPAIR** - two evidence claims corrected (check count; the exact Qwen session sequence, which I had overstated). 002: the **resumed** reviewer finished the recheck but could not replace `EXCHANGE/REVIEW.md` ("access denied"); the helper's new failed-replace rule published nothing; three attempts, then the driver **gave up (exit 5)** with the handoff still due - every invariant held. Cause: the file was owned by a Codex sandbox account and lacked the grant of the later sandbox identity (a controlled resume test elsewhere did not reproduce it). Re-creating the file as the user, same bytes and time, let the **same resumed session** publish its **PASS** in 26 s. The Codex driver now does this re-ownership before each attempt (D20). Later exchanges: 003 REPAIR (a check that never ran, a non-atomic re-own, incomplete redaction), 004 PASS, 005 REPAIR (stale skill zip), 006 final **PASS**; the reviewer's throwaway folders led to `WATCHERS/scratch/`. Side note: my first attempt to repair permissions with `icacls /reset` also removed the sandbox's grants from the task folder; Codex restored them on its next run. |

### Platform findings from live runs (each fixed or documented)

- Codex on Windows: its sandbox refuses to spawn the WindowsApps `pwsh.exe` ("Access is denied").
  The reviewer worked around it by following the manual protocol. Fix: prompts now call the
  helper in-process (`& looper.ps1 ...`), and the helper runs on Windows PowerShell 5.1 too.
- PowerShell passes `$null` to .NET as `""`: `File.Replace(tmp, target, $null)` failed. Fixed with `[NullString]::Value`.
- `pwsh -File` cannot pass string arrays and treats values starting with `-` as parameter
  names. Driver `-Extra` is now one string, passed as `-Extra:"--flag value"`.
- Codex `workspace-write` keeps `.git` read-only; `--add-dir <repo>/.git` is refused on Windows.
  A sandboxed Codex worker cannot commit. Documented; `-Sandbox` option added (user's choice).

## Not proven / limits

- Multi-hour runs: the longest loops are well under an hour. Nothing in the design depends on
  duration, but a long real task is still the missing proof.
- macOS/BSD tools and busybox have not been run (Linux dash and Git Bash sh have).
- OpenCode was tested once, in a Linux container, and has no driver script yet.
- Local models: 4 of 4 Looper review runs through Claude Code or OpenCode were correct once the
  context window was large enough, but an unconstrained probe gave a wrong answer; not yet
  trusted as the only reviewer of consequential work. Codex + the tested Qwen models did not work.
- The Codex Windows sandbox permission problem (E12) was diagnosed and mitigated but could not be
  reproduced on demand, so the exact trigger is unknown.
- Skills were checked with Claude Code and Codex CLIs and the official Codex validator; the ChatGPT
  desktop app's upload path was not exercised.
