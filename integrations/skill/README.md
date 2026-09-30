# Looper as an Agent Skill

Optional convenience. Portable use (clone the repo, point an agent at `prompts/worker.md`) is the
reference; the skill lets you say "use Looper for this task" without a path.

`SKILL.md` (open Agent Skills format) and `agents/openai.yaml` (OpenAI UI metadata: display
name, short description, default prompt `$looper`) are the only skill-specific files.
`build.ps1` generates the package by copying the canonical `template/`, `prompts/`, `tools/`,
`drivers/`, `docs/contract.md` and `LICENSE` next to them - a copy, never a fork. Rebuild after
changing Looper; the build verifies every packaged file (and the zip) byte-for-byte against the
repository, and `-Check` verifies an existing package without rebuilding. A rebuild replaces only
a package the build generated (or an empty folder), never one that holds this repository or
contains a link; it refuses any other existing `-Out`.

```powershell
pwsh -File integrations/skill/build.ps1 -Out ~/.claude/skills/looper   # Claude Code (personal)
pwsh -File integrations/skill/build.ps1 -Out ~/.agents/skills/looper   # Codex (personal)
pwsh -File integrations/skill/build.ps1                                 # dist/looper/ + dist/looper-skill.zip
pwsh -File integrations/skill/build.ps1 -Check                          # is the existing package current?
```

Project installs work too: `<project>/.claude/skills/looper` or `<project>/.agents/skills/looper`.
Use the zip where an app installs skills by upload (for example a ChatGPT surface that supports
skill upload - not yet exercised).

Checked 2026-09-27: the generated folder passes the official Codex `skill-creator/quick_validate.py`
("Skill is valid!"), and `openai.yaml` follows its reference (quoted strings, 25-64 character short
description, default prompt naming `$looper`). Live: Claude Code (project skill) and Codex
(`.agents/skills`) each created a Looper task and published a first handoff from "Use Looper for
this task: ..." with no Looper path given (docs/testing.md, E11).
