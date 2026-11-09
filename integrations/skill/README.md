# Looper as an Agent Skill

Optional convenience. Portable use (clone the repo, point an agent at `prompts/worker.md`) is the
reference; the skill lets you say "use Looper for this task" without a path.

`SKILL.md` (open Agent Skills format) and `agents/openai.yaml` (OpenAI UI metadata: display
name, short description, default prompt `$looper`) are the only skill-specific files.
`build.ps1` generates the package by copying the canonical `template/`, `prompts/`, `tools/`,
`drivers/`, `docs/contract.md` and `LICENSE` next to them - a copy, never a fork. Rebuild after
changing Looper. The build and `-Check` (which does not rebuild) compare the package, and for
`dist/` the zip, with the paths and SHA-256 hashes of the sources, hidden files included on every
OS: a missing, extra or changed file fails. A rebuild replaces only
a package the build generated (or an empty folder), never one that holds this repository or
contains a link; it refuses any other existing `-Out`. Likewise the default `dist/looper-skill.zip` is replaced only
if it is a generated package (every entry under `looper/`, with `looper/VERSION`).

`VERSION` identifies the source (PowerShell 7 or Windows PowerShell 5.1 can build):

```text
generator: Looper skill build
repository: https://github.com/shedstalker/looper.git
commit: 0123456789abcdef0123456789abcdef01234567
dirty: false
describe: v0.4.0
date: 2026-11-08
git: available
```

`repository` is the origin URL without credentials; `dirty` means tracked files differed from
`commit` (untracked files are ignored); unknown values say `unknown`, and a build without git
records `git: unavailable`. A dirty install matches no commit: compare it with `-Check` instead.

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
