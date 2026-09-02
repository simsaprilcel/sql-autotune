# Configuring Gemini CLI for the Command Line

The Gemini equivalent of [`claude-cli-setup.md`](claude-cli-setup.md) — same harness, same `program.md`, different agent CLI underneath. Read that doc first; this one only calls out what's different.

> Gemini CLI moves fast too. Check `gemini --help` and the [official docs](https://geminicli.com/docs/) before standardizing on flags institution-wide.

---

## 1. Install

```bash
npm install -g @google/gemini-cli
```

Verify:

```bash
gemini --version
```

---

## 2. Authentication

| | Google account (OAuth) | API key (AI Studio / Vertex) |
|---|---|---|
| Sign-in | `gemini` → browser OAuth | `GEMINI_API_KEY` env var |
| Billing | Free tier + Google One AI plans | Metered per token |
| Best for | Interactive work at a desk | Servers, automation, cron, CI |
| Headless-friendly | Needs a browser once | Yes |

For unattended runs, use an API key in a root-only environment file — same pattern as the Claude doc:

```bash
sudo install -m 600 /dev/null /etc/sql-autotune-gemini.env
sudo tee /etc/sql-autotune-gemini.env >/dev/null <<'EOF'
GEMINI_API_KEY=AI...
EOF
```

Reference it from a systemd `EnvironmentFile=` or source it inside a cron job — never in the crontab itself.

---

## 3. Interactive use on a desktop

```bash
cd ~/Projects/sql-autotune
gemini                        # start a session in this directory
gemini "explain query.sql"    # start with an opening prompt
```

Gemini CLI's session-resume story is thinner than Claude Code's `--continue`/`--resume` — this repo doesn't depend on it either way, since state lives in git and `results.tsv`, not the session.

---

## 4. Headless / non-interactive — what `start-gemini.sh` uses

```bash
gemini -p "Read program.md and begin." \
    --approval-mode auto_edit \
    --model gemini-2.5-pro
```

| Flag | Purpose | Claude Code equivalent |
|---|---|---|
| `-p` / `--prompt` | Non-interactive: run the prompt, print the result, exit | `-p` |
| `--approval-mode` | `default` (prompt), `auto_edit` (auto-approve edits), `yolo` (auto-approve everything), `plan` (read-only) | `--allowedTools` + permission mode |
| `--model` | Pin a model for reproducibility | `--model` |
| `--output-format json` | Machine-readable result | `--output-format json` |

**No `--max-turns` flag.** The turn ceiling is a setting, not a flag: `model.maxSessionTurns` in `.gemini/settings.json`. `start-gemini.sh` writes that value before launching rather than passing it on the command line. Gemini CLI enforces its own ceiling independently and exits with code `53` if it's hit — `start-gemini.sh` treats that exit code the same as a clean stop, exactly like a Claude session ending on `--max-turns`.

There is no `auto_edit`-equivalent granularity for *shell commands* the way `--allowedTools "Edit,Read,Write,Bash,Glob,Grep"` names tool categories — see the permissions section below for why that matters here.

### Keeping a long run alive

Identical pattern to the Claude doc:

```bash
tmux new -s autotune './start-gemini.sh --loop 50'
```

---

## 5. Permissions and `.gemini/settings.json` — the part that isn't a drop-in swap

Claude Code's `.claude/settings.json` denies **specific file paths**: `Read(./baseline_results.csv)` is a hard boundary regardless of what the model decides. Gemini CLI's tool config is **coarser-grained** — it operates on tool names and shell command prefixes, not file-path globs:

```json
{
  "tools": {
    "allowed": [
      "run_shell_command(./prepare.sh)",
      "run_shell_command(git add)",
      "run_shell_command(git commit)",
      "run_shell_command(git reset)",
      "run_shell_command(git log)",
      "run_shell_command(git status)"
    ],
    "exclude": [
      "run_shell_command(sql)",
      "run_shell_command(sqlplus)"
    ]
  },
  "model": {
    "maxSessionTurns": 110
  }
}
```

`tools.allowed` bypasses the confirmation prompt (comparable to Claude's `allow` list under `default` mode). `tools.exclude` removes a tool from discovery entirely — the closer analog to a hard `deny`.

**The gap:** there is no `Read(./baseline_results.csv)` equivalent. Gemini's `read_file` tool is allowed or excluded as a whole — you cannot exclude it for three specific filenames while leaving `query.sql` and `program.md` readable through the same config surface. Excluding `read_file` entirely breaks the agent's ability to read `query.sql` and `program.md`, which defeats the point.

That means the file-level boundary this repo relies on has to move down a layer, to something Gemini CLI's settings can't undo:

- **OS file permissions.** Run the agent as a user that cannot read `baseline_results.csv`, `run_results.csv`, `run_raw.csv` at all (`chmod 600`, owned by a different account, or a group the agent's user isn't in). This is arguably *more* robust than a CLI-level deny rule anyway — it holds even if `.gemini/settings.json` is misconfigured or bypassed.
- **The sandbox.** `tools.sandbox: true` (or `docker`/`podman`) runs tool execution in a container. Mount only `query.sql`, `program.md`, `config.sh`, `results.tsv`, and `prepare.sh` into it — the result CSVs simply don't exist inside the sandbox's filesystem.

Either approach gets you back to "a claim you can point at for a compliance conversation" — it just isn't expressed in the same JSON file as the model's tool list anymore. Say this explicitly on stage: the *tool-permission* model differs, not just the flag names, and the fix is architectural (OS/container boundary) rather than a config tweak.

`prepare.sh`'s own `sql:*` deny still matters here for the same reason it does in the Claude setup — it stops the agent from running ad hoc queries outside the harness, which is a shell-command-prefix restriction and *does* map cleanly to `tools.exclude`.

---

## 6. Project context: `GEMINI.md`

Same idea as `CLAUDE.md`, different filename. Loaded automatically from the project root (and up to 200 parent directories, and `~/.gemini/GEMINI.md` for user-wide conventions). If you already wrote a `CLAUDE.md` for this repo, copy it to `GEMINI.md` — the content isn't Claude-specific.

---

## 7. Which model

| Model | ID | Use for |
|---|---|---|
| Gemini 3 Pro | `gemini-3-pro` | Complex reasoning, agentic and long-horizon work (needs access; falls back to 2.5 Pro otherwise) |
| Gemini 2.5 Pro | `gemini-2.5-pro` | Default-quality reasoning where 3 Pro isn't available |
| Gemini 2.5 Flash | `gemini-2.5-flash` | High-volume, latency-sensitive work |

By default Gemini CLI auto-routes between these based on prompt complexity. For a tuning loop, pin one explicitly with `--model` — auto-routing means two runs on the same query could silently use different models, which breaks any before/after comparison.

---

## 8. Server checklist

Same list as the Claude doc, with the file-boundary line adjusted:

- [ ] Non-production database. A clone still contains real student data.
- [ ] Query-only account. No DML, no DDL, no access to schemas the task doesn't need.
- [ ] Oracle Wallet for the connection, so no password sits in `config.sh` or reaches a prompt.
- [ ] `GEMINI_API_KEY` in a root-only environment file, not a dotfile, never in git.
- [ ] `.gemini/settings.json` committed, with `tools.exclude` covering `sql`/`sqlplus`.
- [ ] Result CSVs blocked by **OS permissions or sandbox mount**, not by settings.json alone — see §5.
- [ ] `--approval-mode` and a `model.maxSessionTurns` ceiling set on every headless invocation.
- [ ] Long runs under tmux or systemd, with output to a log you can read afterward.
- [ ] `.gitignore` covers result files, logs, and anything containing real rows.
- [ ] One dry run watched end to end before anything runs unattended.

---

## 9. The honest framing for a talk

`program.md` — the actual optimization loop, the rules, the logging discipline — is CLI-agnostic; it's just an instruction file read by whichever agent you point at it. What doesn't transfer unchanged is the enforcement layer: Claude Code's path-glob deny list is a stronger, more legible primitive than Gemini CLI's tool-name allow/exclude list. Porting this pattern to Gemini is a real port, not a find-and-replace of `claude` for `gemini` — the harness and the data-hiding discipline in `prepare.sh` stay put either way, which is exactly why they were built as bash, not as agent instructions, in the first place.
