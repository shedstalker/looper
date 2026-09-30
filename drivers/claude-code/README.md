# Claude Code driver

Checked with Claude Code 2.1.278 (September 2026); `claude-opus-5-5` needs 2.1.280 or newer. Flags
change; check the current Claude Code docs.

## Worker - visible interactive session (the usual way)

Start Claude Code in the project and say, for example:

```text
Use Looper for this task. Looper is at <looper-home> - read its prompts/worker.md.
Task: <what you want>. Reviewer: <e.g. Codex via drivers/codex/run.ps1>.
```

After each handoff the worker runs the helper's `wait <folder> -For worker` as a **background**
command and keeps working. When it exits (answer published, or task done) Claude Code
re-invokes the session with its output. Exit 3 is a quiet timeout (default 12 h): start it
again. No model calls while waiting. A replaced session only needs:
`Continue the Looper task at <folder> as the WORKER - read its CONTEXT.md.`

### Permissions: cover every task folder before you start

Claude Code, not the model, decides which commands run. If the session works in auto mode or
with an allow-list, set it up once for Looper:
- **Folders:** `permissions.additionalDirectories` (or `--add-dir`) for every folder the session
  and its subagents will use. That means every task folder, not only the first. A parent folder
  holding all task folders is simplest.
- **Commands, with an allow-list:** allow rules for the helper and any driver it starts (for
  example `Bash(pwsh *)`, `Bash(sh *)` or the `PowerShell` tool).
- **Commands, in auto mode:** broad interpreter rules like those are set aside, and the classifier
  decides each command. Add a plain-language line to `autoMode.environment` saying that running
  the Looper helper and drivers on those task folders is intended.

Subagents inherit the session's rules, so one entry covers them. Claude Code reloads permission
edits in a running session, so no restart is needed. An agent must not widen its own permissions:
when Claude Code refuses a Looper command, the agent stops and asks you. (From real use: lanes
run by subagents on their own task folders were refused until the owner's settings named those
folders too.)

## Worker or reviewer - headless

```powershell
pwsh -File drivers/claude-code/run.ps1 -Loop <folder>                    # reviewer
pwsh -File drivers/claude-code/run.ps1 -Loop <folder> -Role worker
pwsh -File drivers/claude-code/run.ps1 -Loop <folder> -Model claude-opus-5-5 -Effort high -Session fresh -Show
```

- `-Session resume` (default) continues the role's Claude session (`--resume <id>`); if Claude
  says the session no longer exists, the driver cold-starts a new one in the same attempt.
  `-Session fresh` gives every attempt a new session.
- `-Model` / `-Effort` map to `--model` / `--effort`. The log records what was requested and the
  model Claude reports using; Claude Code does not report the effort level.
- `-Show` streams output as it arrives (Claude's JSON result arrives at the end of each attempt)
  and prints `claude --resume <id>` so you can open the session yourself between attempts.
- `-Local <ollama-model>` runs Claude Code against a local model through Ollama's
  Anthropic-compatible API (see `drivers/README.md`: the model needs a large context window).

Command line built (logged in `WATCHERS/<role>.log`):

```text
claude -p --output-format json --add-dir <looper-home>
  reviewer: --permission-mode dontAsk --add-dir <project>   (cwd = task folder)
  worker:   --permission-mode acceptEdits --add-dir <task>  (cwd = project)
  --allowedTools Read,Grep,Glob,Write,Edit,PowerShell,Bash(pwsh *),Bash(sh *),Bash(git *)
  [--model M] [--effort E] [--resume <id>]
```

`dontAsk` refuses anything not allowed instead of hanging on a prompt. Add test commands with
`-Extra:"--allowedTools 'Bash(npm test *)'"`. Keeping the reviewer out of the worker's source is a
role rule (and visible in `git status`), not a sandbox guarantee - the allow-list includes shells
so the agent can run the helper. Headless `claude -p` runs the project's hooks and MCP servers;
`-Extra:"--bare"` avoids that (it requires an API key).

## Other visible options

`claude --bg` starts a supervised background session you can `claude attach <id>` to. It is not
used by the driver because the driver needs to know when an attempt has finished; a visible
interactive worker waiting on the helper covers the "watch it work" case.
