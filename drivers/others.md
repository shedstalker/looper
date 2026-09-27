# Other agent CLIs

Surveyed 2026-09-27 from each project's current documentation, plus live tests where noted.
An agent fits Looper naturally when it can run headless in a chosen directory with a prompt,
read/write files and run a shell (to call the helper), and ideally resume a session, select a
model and report what it used. Looper needs none of this to work - any agent can be driven by
hand with the one-line prompt - so this list only decides where a driver script is worth having.

## Tested

**OpenCode** (`opencode run`, v1.18.32) - the best fit found. `--dir`, `-s <session>` (resume),
`-m provider/model`, `--variant` (effort), `--format json` (session id in events), `--auto`
(approve permissions), native Windows/macOS/Linux, and Ollama as an ordinary provider.
Live test (E10): in a throwaway Linux container, `opencode run --dir <task> -m
ollama/<qwen3.6 64k> --auto --format json "<one-line reviewer prompt>"` against the host's
Ollama published a correct REPAIR (ran the script, 9 vs 15, right root cause) in 70 s - the
fastest local route tested. Its JSON events carry the session id but not the model used. No
driver script is included yet: the command above is the whole
adapter, and one run is not enough evidence to maintain one. Ollama provider config for OpenCode:

```json
{"provider": {"ollama": {"npm": "@ai-sdk/openai-compatible", "name": "Ollama",
  "options": {"baseURL": "http://localhost:11434/v1"},
  "models": {"qwen36-64k": {"name": "qwen3.6 64k"}}}}}
```

## Documented fits (not tested here)

| CLI | Headless | Resume | Model / effort | Permissions | JSON | Notes |
|---|---|---|---|---|---|---|
| Qwen Code | `-p`, stdin | `--resume <id>` | `-m` / none | `--yolo`, `--approval-mode` | yes | Gemini CLI fork; Ollama; now needs an API key or a local model |
| GitHub Copilot CLI | `-p`, stdin | `--resume=<id>` | `--model` / `--reasoning-effort` | `--allow-all-tools`, `--allow-tool` | yes | `-C <dir>`; BYOK incl. local; needs a Copilot subscription |
| Gemini CLI | `-p`, stdin | `--resume <id>` | `-m` / settings only | `--approval-mode yolo` | yes | no Ollama; generous free tier |
| Cline CLI | `cline "<task>"` | `--id` | `-m` / `--thinking` | auto-approve by default | NDJSON | Windows support not clearly documented |

Each would be a ~50-line `run.ps1` like `codex/run.ps1`. Add one when someone actually uses it.

## Poor fits

- **Aider** - edits files but only suggests shell commands, so it cannot reliably run the helper; no session ids or JSON.
- **Goose** - resume by session name only, no directory flag, permissions via environment/config; Windows via WSL/Git Bash.
- **Pi** - no permission layer at all; no directory flag.
- **Factory Droid, Kimi Code** - proprietary key or unclear headless permissions.

## Local models, in one line each

- Claude Code -> Ollama (Anthropic API): works with a 64k-context model (E9b).
- OpenCode -> Ollama (OpenAI-compatible API): works (E10).
- Codex `--oss` -> Ollama: the tested Qwen models could not use Codex's tools (E9a).
