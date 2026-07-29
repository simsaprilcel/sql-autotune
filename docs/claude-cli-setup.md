# Configuring Claude for the Command Line

Everything needed to get from "nothing installed" to "an agent can run `./start.sh` unattended," on a desktop and on a server. Written for a Banner/Oracle shop, but nothing here is Banner-specific except the examples.

> Versions move fast. Treat the commands below as the shape of the thing and check `claude --help`, `/help`, and the official docs for current flags before standardizing on them institution-wide.

---

## 1. Install

Three options. Pick one and be consistent across the team.

```bash
# Native installer (recommended — self-updating, no Node required)
curl -fsSL https://claude.ai/install.sh | bash

# npm (needs Node 18+)
npm install -g @anthropic-ai/claude-code

# Homebrew (macOS)
brew install --cask claude-code
```

Verify:

```bash
claude --version
claude doctor     # environment diagnostics: install method, versions, auth state
```

Claude Code also ships as a desktop app, a web app at claude.ai/code, and IDE extensions for VS Code and JetBrains. The CLI is the one that matters here — it's what a harness like `start.sh` can drive.

---

## 2. Authentication — two models, and the choice matters

| | Subscription (Pro / Max / Team) | API key (Console) |
|---|---|---|
| Sign-in | `claude` → `/login`, browser OAuth | `ANTHROPIC_API_KEY` env var |
| Billing | Flat monthly, usage limits | Metered per token |
| Best for | Interactive work at a desk | Servers, automation, cron, CI |
| Headless-friendly | Needs a browser once | Yes |
| Attribution | Per person | Per key — issue one per purpose |

For a shop standing this up: developers use subscriptions for interactive work; anything unattended runs on an API key so spend and revocation are per-workload rather than per-person.

Check what's active at any time:

```bash
claude          # then: /status
```

**Precedence gotcha.** An exported `ANTHROPIC_API_KEY` outranks an interactive login. If someone logs in with `/login` and also has a key exported in their shell profile, requests silently bill to the key's organization. Worse, an *empty* `ANTHROPIC_API_KEY=""` still occupies the slot and authenticates with an empty key. Truly `unset` it, or scope it to the command:

```bash
env -u ANTHROPIC_API_KEY claude       # one-off, ignore the key
```

The same precedence applies to the `ant` CLI and the Anthropic SDKs, which resolve credentials in the same order (`ANTHROPIC_API_KEY` → `ANTHROPIC_AUTH_TOKEN` → an `ant auth login` profile → workload identity → default profile). If you have both an `ant` profile and a Claude Code login, keep one — Claude Code will warn about the conflict.

### Storing the key on a server

Never in a dotfile that's world-readable, never in git.

```bash
# systemd service — key lives in a root-only environment file
sudo install -m 600 /dev/null /etc/sql-autotune.env
sudo tee /etc/sql-autotune.env >/dev/null <<'EOF'
ANTHROPIC_API_KEY=sk-ant-...
EOF
```

Then reference it from the unit (`EnvironmentFile=/etc/sql-autotune.env`). For cron, source the same file inside the job rather than putting the key in the crontab.

---

## 3. Interactive use on a desktop

```bash
cd ~/Projects/sql-autotune
claude                       # start a session in this directory
claude "explain query.sql"   # start with an opening prompt
claude --continue            # resume the most recent session here
claude --resume              # pick from a list of past sessions
```

Useful in-session commands: `/help`, `/status`, `/config`, `/model`, `/permissions`, `/clear`, `/init` (generate a `CLAUDE.md`), `/cost`.

Prefixing a shell command with `!` runs it and puts the output in the conversation — handy for interactive logins the agent can't do itself (`! gcloud auth login`).

---

## 4. Headless / non-interactive — what `start.sh` uses

This is the mode that makes an autonomous loop possible:

```bash
claude -p "Read program.md and begin." \
    --allowedTools "Edit,Read,Write,Bash,Glob,Grep" \
    --max-turns 110
```

| Flag | Purpose |
|---|---|
| `-p` / `--print` | Non-interactive: run the prompt, print the result, exit |
| `--allowedTools` | Whitelist of tools the agent may use without prompting |
| `--max-turns` | Hard ceiling on agent turns — the runaway backstop |
| `--output-format json` | Machine-readable result, for harnesses that parse it |
| `--model` | Pin a model for reproducibility across runs |
| `--append-system-prompt` | Add standing instructions for this invocation |

`start.sh` in this repo computes `--max-turns` from `MAX_ITERATIONS` (roughly five turns per experiment plus overhead) so a stuck agent stops rather than burning tokens overnight.

### Keeping a long run alive

An unattended tuning run can take hours. Detach it:

```bash
tmux new -s autotune './start.sh --loop 50'
tmux attach -t autotune          # check on it later
```

`--loop` restarts the session when it ends (context exhaustion, for example), and the agent resumes from `results.tsv` because `program.md` tells it to read that file first. State lives in git and a TSV, not in the session — which is what makes restarting safe.

---

## 5. Permissions and `settings.json`

Three layers, most specific winning:

| File | Scope | In git? |
|---|---|---|
| `~/.claude/settings.json` | The user, everywhere | No |
| `<project>/.claude/settings.json` | The project, everyone | **Yes** — this is the shared policy |
| `<project>/.claude/settings.local.json` | The project, just you | No (gitignore it) |

A starting policy for a repo like this one — pre-approve the harness, deny the data:

```json
{
  "permissions": {
    "allow": [
      "Bash(./prepare.sh:*)",
      "Bash(git add:*)",
      "Bash(git commit:*)",
      "Bash(git reset --hard:*)",
      "Bash(git log:*)",
      "Bash(grep:*)",
      "Read(./program.md)",
      "Read(./query.sql)",
      "Edit(./query.sql)"
    ],
    "deny": [
      "Read(./baseline_results.csv)",
      "Read(./run_results.csv)",
      "Read(./run_raw.csv)",
      "Bash(sql:*)",
      "Read(./.env)",
      "Read(**/*wallet*)",
      "Read(**/id_rsa*)"
    ]
  },
  "env": {
    "TNS_ADMIN": "/opt/oracle/network/admin"
  }
}
```

Those `deny` rules are the point worth dwelling on. `program.md` *tells* the agent not to read the result CSVs — but a prompt is an instruction, not a boundary. A deny rule is enforced by the harness, so it holds regardless of what the model decides. If you make a claim to a compliance office about what the agent can and cannot see, the deny list is the thing you can actually point at.

Permission modes, from most to least supervised:

| Mode | Behavior |
|---|---|
| `default` | Prompts before anything not pre-approved |
| `acceptEdits` | Auto-accepts file edits, still prompts for commands |
| `plan` | Read-only: investigates and proposes, changes nothing |
| `bypassPermissions` | No prompts at all |

`--dangerously-skip-permissions` (the flag form of bypass) is how people get an unattended agent working quickly, and it's the wrong tool for it. A specific `--allowedTools` list plus a deny list in `settings.json` gets you the same unattended behavior with a boundary still in place. Reserve bypass for a throwaway container with no credentials and no data.

---

## 6. Project context: `CLAUDE.md`

A `CLAUDE.md` at the repo root is loaded automatically into every session in that directory. It's where conventions live so you don't retype them:

```markdown
# Conventions
- Oracle 19c. SQLcl (`sql`), not sqlplus.
- Never DDL against a Banner schema — read-only analysis only.
- Judge SQL by execution plan and buffer gets, not wall clock.
```

Generate a starting point with `/init`. Keep it in git — it's shared institutional knowledge, and it's the cheapest onboarding document you'll ever write.

---

## 7. Which model

| Model | ID | Use for |
|---|---|---|
| Claude Opus 5 | `claude-opus-5` | Default. Complex reasoning, agentic and long-horizon work |
| Claude Sonnet 5 | `claude-sonnet-5` | High-volume work where cost matters more than depth |
| Claude Haiku 4.5 | `claude-haiku-4-5` | Simple, latency-sensitive tasks |

Set per session with `/model`, per invocation with `--model`, or as a default in `settings.json`. For a tuning loop, pin it: comparing today's results against last month's is only meaningful if the same model produced both.

---

## 8. Server checklist

Before pointing an unattended agent at a database:

- [ ] Non-production database. A clone still contains real student data — "non-prod" is not "safe to send anywhere."
- [ ] Query-only account. No DML, no DDL, no access to schemas the task doesn't need.
- [ ] Oracle Wallet for the connection, so no password sits in `config.sh` or reaches a prompt.
- [ ] `ANTHROPIC_API_KEY` in a root-only environment file, not a dotfile, never in git.
- [ ] `.claude/settings.json` committed, with a deny list covering result files, wallets, and keys.
- [ ] `--allowedTools` and `--max-turns` set on every headless invocation.
- [ ] Long runs under tmux or systemd, with output to a log you can read afterward.
- [ ] `.gitignore` covers result files, logs, and anything containing real rows.
- [ ] One dry run watched end to end before anything runs unattended.

---

## 9. Self-hosting instead

If policy won't allow an external API at all, run an open model locally (Ollama, vLLM, llama.cpp) — data never leaves the building, and you trade away a large amount of capability, absorb the GPU and operations cost, and own the upgrade treadmill. It's a real option and worth naming, but be honest in the comparison: for agentic work of this kind, the gap between a frontier model and a locally-hosted open one is currently the difference between the loop working and the loop not working.

The middle path is the one this repo takes: send *structure* (SQL text, schema, timings, a pass/fail verdict) to a vendor API, and keep *data* (result rows) on the machine by construction.
