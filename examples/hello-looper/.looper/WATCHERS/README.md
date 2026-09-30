# WATCHERS

Wake-up plumbing only. Nothing here decides whether work is correct, edits source or grants
authority. The truth is always recomputed from the files by `status`.

- Worker: interactive Claude Code session (Opus 5.5, `claude-opus-5-5`), waiting with
  `& 'C:\PROJECTS\Looper\tools\looper.ps1' wait 'C:\Projects\Looper-Test\hello-v032\.looper' -For worker`.
- Reviewer: Codex headless driver, runtime-default model (config.toml), final review settings:
  `pwsh -NoProfile -File 'C:\PROJECTS\Looper\drivers\codex\run.ps1' -Loop 'C:\Projects\Looper-Test\hello-v032\.looper' -Session fresh -Effort xhigh`

Runtime files a driver may leave here: `<role>.lock` (held while a driver runs; released by the
OS if it dies), `<role>.log` (one line per attempt), `<role>-last.txt` and `-last.err` (last child
output), `<role>.session` (the session to resume), `.<role>-prompt.txt` (the prompt passed).
