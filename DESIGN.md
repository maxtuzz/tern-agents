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
