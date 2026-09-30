# Contributing

Thanks for looking. Looper is small on purpose, so the most useful contributions are usually
reports: something that surprised you, a runtime or model you ran it with, or a place where the
docs sent you the wrong way.

## Reporting a problem

Open an issue and include what makes a Looper problem reproducible:

- the Looper version (`VERSION` in a Skill install, `git describe --tags` in a clone, or the
  release you downloaded);
- the runtime and model for each role (Claude Code, Codex CLI or OpenCode, plus the model), and
  whether it ran visible, headless (a driver) or by hand;
- your OS and shell, and which helper you used (`looper.ps1` or `looper.sh`);
- the output of `status` on the task folder;
- the relevant lines from `WATCHERS/<role>.log`, if a driver was involved.

Please don't paste credentials, API keys, sign-in files (`auth.json`) or private task content. A
short excerpt of a `HANDOFF.md` or `REVIEW.md` is usually enough.

## Proposing a change

Issues and pull requests are welcome as proposals. Changes are developed and independently
reviewed in the maintainers' development repository (Looper reviews its own changes, with a
different model as the reviewer) and come back here in a reviewed release, so a pull request may
be reworked rather than merged as-is.

What gets accepted is shaped by a few house rules:

- **Level 1 stays the smallest useful tool.** Add something only when a check or real use fails
  without it. Deleting beats adding.
- **The core names no provider.** `template/`, `prompts/`, `tools/` and `docs/contract.md` work
  with any agent; provider details live under `drivers/`.
- **Three runtimes have drivers: Claude Code, Codex CLI and OpenCode.** New models go through
  OpenCode. Other agents can take part by hand; there are no drivers for more CLIs.
- **Evidence over claims.** "A runtime offers this model" is not "this model passed a Looper
  handoff". Record what was actually run in `docs/testing.md`, including what failed.
- **The protocol must keep working by hand.** Scripts are conveniences, never requirements.

## Running the checks

```powershell
pwsh -File tests/acceptance.ps1              # PowerShell helper
pwsh -File tests/acceptance.ps1 -Helper sh   # POSIX sh helper (needs sh on PATH, e.g. Git Bash)
```

No model calls, a few minutes each. They also run on Windows PowerShell 5.1 (the driver checks
are skipped there, since drivers need PowerShell 7).
