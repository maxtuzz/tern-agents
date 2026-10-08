# Design: tern-agents

Status: seed. The implementation PR fills in the details; this file records the research the design rests on.

## Goal

Tern's agent blocks are bound to omp. Make them run whatever agent CLI the user has (claude, codex, gemini, opencode, cursor-agent, aider, custom), with named run presets, the way Orca's agent launcher does.

## How Tern's agent blocks work (Tern 0.5.2)

- An **agent block** is a pane of kind `"agent"`: a program with a terminal surface. **New agent block** (action `new_agent_block`, cmd+shift+a) runs the `agent_command` setting (default `omp`) and places it by `agent_placement` (`replace_if_alone` default, `split`, `tab`).
- The binding to omp is in the *extras*, not the block: omp speaks the Tern Surface Protocol (TSP), so Tern draws its chat natively, reports `sendable` from its composer, reads its transcript (`cx.agents:transcript`), and gets working/idle from progress OSC 9;4. Hermes got the same treatment by speaking omp's chat vocabulary. A plain TUI agent gets the block, the Agent chip and Carly visibility, but none of the omp-only extras.
- Window API `cx.agents` (`tern.d.luau`, `AgentsCx`):
  - `start({prompt, cwd, command?, how?}) -> pane` opens like New agent block; `command` is any command line. **`prompt` must be non-blank** ("agent command, cwd and prompt must not be blank").
  - `list()` → `{pane, command, agent_command, model, cwd, state, last_message, title, program, session, tab, alive, ...}` across sessions.
  - `ask`, `wait`, `transcript`, `interrupt` (Ctrl-C), `stop` (close without confirmation).

### Measured with Claude Code 2.1 in an agent block (2026-10-08)

- `cx.agents:start({command = "claude --model haiku", ...})` spawns the program **without the user's interactive shell environment**: `claude`'s `#!/usr/bin/env node` picked Homebrew's Node 26 instead of the nvm Node on the user's PATH and crashed (block shows `exited 1`). Wrapping as `/bin/zsh -lic "exec claude …"` works. The launcher must resolve the user's environment (interactive login shell, or an explicit PATH) rather than relying on the spawn environment.
- The prompt **is** delivered: Claude received it, answered, and set the pane title (`✳ <task title>`).
- `state` stays `"working"` forever (Claude emits no OSC 9;4 here), so `cx.agents:wait` times out and the block never reads idle. `transcript` returns `{}`.
- After a `start` with a prompt, `ask` fails with "agent already has a pending prompt" (Tern never sees `sendable` from a non-TSP composer). Follow-up prompts must be typed into the pane (`cx:run(pane, text .. "\r")` / `tern.pane.write`).
- `stop` closes the block.
- Claude Code's terminal title carries its state: `✳` idle, a spinner glyph (`◐`/`◑`/…) while working. That, plus `exited`, is the usable status signal for Claude.

## Orca's agent model (Orca 1.4.222, `orca-data.json` → `settings`)

- `defaultTuiAgent` (e.g. `omp`), `disabledTuiAgents`.
- `agentCmdOverrides`: agent id → full command line (e.g. `claude` → `claude --dangerously-skip-permissions`; `codex` → `codex -c model_reasoning_effort="high" --ask-for-approval never --sandbox danger-full-access …`).
- `agentDefaultArgs`: agent id → "yolo" args (`gemini --yolo`, `cursor --yolo`, `aider --yes-always`, `amp --dangerously-allow-all`, `qwen-code --approval-mode yolo`, `grok --permission-mode bypassPermissions`, `copilot --yolo`, `hermes --yolo`, …).
- `agentDefaultEnv`: agent id → env (e.g. `goose` → `GOOSE_MODE=auto`).
- `terminalQuickCommands`: saved launchers, including `action = "agent-prompt"` with an agent and prompt.
- `agentStatusHooksEnabled`: Orca installs per-agent status hooks for working/idle.

## Constraints

- No plugin-settings API (`cx.settings` covers Tern's own keys only): config lives in `tern.kv` plus an optional hand-edited JSON file in the plugin data dir, hand entries win (same as tern-worktrees).
- Use only real Tern APIs; document every limitation in the README.

## What the plugin does with that (0.1.0)

### Two launch paths, because `start` needs a prompt

| Launch | Path | Result |
| --- | --- | --- |
| With a prompt | `cx.agents:start{prompt, cwd, command, how}` | A real agent block: kind `agent`, the Agent chip, in `cx.agents:list()`. |
| Without a prompt | `cx.layout:split`/`new_tab{cwd, command}` | A terminal pane running the same command line. |
| `prompt_delivery = "argv"` | as above, prompt appended to the agent's own CLI | A terminal pane; `start` would deliver the prompt a second time. |

Option (a) from the brief — putting the prompt on the agent's own command line
— is supported as `prompt_delivery = "argv"` per agent, per preset or globally,
and the profiles record how each CLI takes one (`prompt_arg`: `positional` for
claude, codex, cursor-agent, grok and omp; `--prompt` for opencode; `-i` for
the Gemini-family CLIs; `none` for aider, goose, amp, copilot, crush and
hermes, whose prompt flags are one-shot). It is not the default: Tern's own
delivery works, and a real agent block is worth more than argv tidiness.

Option (c) — setting the `agent_command` preference, running Tern's
`new_agent_block` and restoring it — is **rejected**. `cx.settings:set` is
global: it races every other window, and any failure between the two writes
would leave the user's `agent_command` pointing at an agent they never chose.
A launch is not worth that.

### Shell wrapping

Every command line is wrapped as `$SHELL -lic "exec <command>"` (from
`tern.getenv("SHELL")`, else `/bin/zsh`), because the spawn environment lacks
the user's interactive PATH (finding above). `shell = false` opts out globally,
per agent or per preset. The alternative — resolving the PATH once with
`tern.process.run` and caching it — was rejected for launching: it would fix
PATH but not the rest of the user's rc files (nvm shims, `direnv`, agent
wrappers, `GOOSE_MODE`-style exports), and a cached PATH goes stale silently.
The same login shell is used, once, for **detection**, where the only question
is whether a binary exists (`command -v`, cached 15 minutes).

### Status

`exited` (host `pane_exited` → the launch record; `PaneInfo.exited`), then the
pane title (`✳` idle / spinner working for Claude; spinner-only for the other
TUIs), then `PaneInfo.busy`, then `running` — never a claim the API can't
support. Panes that are gone read `closed` and their records are pruned.

### Where state lives

- `tern.kv` `config` — the palette's own agent profiles, presets and defaults.
- `agents.json` in the plugin **data** dir — hand-edited, wins over `config`.
- `tern.kv` `runs` — pane → {agent, preset, cwd, command, started_at, kind},
  so the block, the status line, Restart and `running()` survive reloads.
- `tern.kv` `detected` — the last login-shell probe, with the shell it asked.

Nothing is ever written inside the plugin directory (that would trigger a
reload and cancel timers).

### Smoke test (2026-10-08, Tern 0.5.2)

A `claude:haiku` preset launched through the plugin's own link route ran
`/bin/zsh -lic "exec claude --model haiku"` in a real agent block, received
its prompt, answered, and left the pane titled `✳ PONG reply` — idle by the
heuristic above. The record landed in `kv.json` with `kind = "block"`; closing
the pane and the session left nothing behind.
