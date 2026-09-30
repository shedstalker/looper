# Generic driver - any capable agent

Looper needs only that an agent can read and write files (and ideally run one of the helpers,
`tools/looper.ps1` or `tools/looper.sh`). Any agent can take either role with `prompts/`.

## Manual or heartbeat

Give the agent the one-line prompt for its role (printed by the helper's `new`):

```text
You are the REVIEWER for the Looper task at <folder>. Read <folder>/CONTEXT.md and follow the reviewer route.
```

Send the same line again each time you want it to check (manually, or from a scheduler every
few minutes). The first thing the role does is `status`; if nothing is due it stops at once.

## agent-loop.ps1 - headless agents

The shared loop behind the three supported drivers (Claude Code, Codex, OpenCode). It works with
any CLI that accepts a prompt on stdin, but other CLIs are not supported drivers:

```powershell
pwsh -File drivers/generic/agent-loop.ps1 -Loop <folder> -Role reviewer -Exe <cli> -Arguments <args...>
```

It waits for due work without calling a model, holds `WATCHERS/<role>.lock` so only one
driver per role runs, starts the CLI with the tiny prompt, and afterwards re-reads the files:

- the CLI published -> log it and wait for the next item;
- it published nothing (crash, timeout, lost runner) -> the work simply stays due; retry after
  `-RetrySeconds`, stop after `-MaxFailures` consecutive failures (exit 5);
- the task is done -> exit 0.

`-Arguments` may use `{LOOP}`, `{PROJECT}` and `{HOME}`. Output of the last attempt is in
`WATCHERS/<role>-last.txt`; one line per attempt in `WATCHERS/<role>.log`.

Optional parameters used by the provider wrappers:

- `-Session fresh|resume` with `-ResumeArguments` (may use `{SESSION}`), `-SessionPattern` (first
  group = the id in the CLI's output) and `-ResumeFailurePattern` (text meaning "that session is
  gone" - the only thing that triggers a cold start). Ids are kept in `WATCHERS/<role>.session`.
- `-Requested` (what you asked for) and `-Report 'name=regex'` (what the runtime says it used) -
  logged separately, never merged.
- `-AttachHint 'cli resume {SESSION}'` - printed after each attempt.
- `-Show` - stream the child's output to this terminal while it runs.
- `-BeforeAttempt {scriptblock}` - provider-specific preparation that must not change file content
  (the Codex wrapper uses it to re-own sandbox-created files on Windows).
