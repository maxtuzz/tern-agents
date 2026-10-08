# tern-agents

Run any coding-agent CLI — Claude Code, Codex, Gemini, OpenCode, Cursor Agent, Aider, or anything custom — as a native [Tern](https://stencil.so/tern) agent block, with named run presets such as `claude --dangerously-skip-permissions`.

Tern's own **New agent block** runs one command (the `agent_command` setting, `omp` by default). This plugin adds agent profiles, per-agent run presets, a launcher, one-line quick entry, a sidebar **Agents** block, a status-line segment and Carly/plugin exports on top of the same agent-block machinery.

```
Quick agent…  ›  claude yolo fix the failing test @~/dev/app
                 └─ agent  └─ preset              └─ directory
```

## Status

Works, and young (0.1.0). Built against Tern's Luau plugin API as shipped in Tern 0.5.2 (`tern.d.luau` in this repo, written by `tern plugin types`). Tern is in closed beta and its plugin API is unversioned, so expect to re-check it against a new build. [DESIGN.md](DESIGN.md) records the measurements the design rests on; **[Tern API limits](#tern-api-limits)** below is the honest list of what the plugin cannot do.

## Install

```bash
git clone https://github.com/maxtuzz/tern-agents ~/src/tern-agents
tern plugin link ~/src/tern-agents
tern plugin reload
```

`tern plugin list` should show `agents … ready`. The plugin runs on macOS and Linux desktops; on iOS its commands hide themselves.

## Commands

All of them live in the palette under **Agents**.

| Command | What it does |
| --- | --- |
| **New agent…** (⌘⇧Y) | Pick an agent and a run preset, then type a prompt. |
| **Quick agent…** | One line: `claude yolo fix the build`. |
| **Launch default preset** | No dialog: starts the global default preset. |
| **Agents** | Opens the Agents block (sidebar-friendly). |
| **Restart agent** | Closes an agent and starts the same preset, in the same directory, with the same prompt. |
| **Kill agent** | Closes an agent's block and ends its program. |
| **Duplicate agent** | A second agent, same preset and directory. |
| **Send prompt to agent…** | Types a follow-up prompt into a running agent. |
| **Add preset…** / **Edit preset…** / **Remove preset…** | The run presets. Built-in presets are hidden rather than deleted. |
| **Set default preset…** | For one agent, or as the global default. |
| **Add agent…** | A profile for a CLI the plugin doesn't ship. |
| **Open agents.json** | The hand-edited config, in the plugin data directory. |
| **Refresh detected agents** | Asks your login shell again what is installed. |
| **Import from Orca** | Copies agent settings out of Orca's `orca-data.json` (read-only). |

Nothing is bound except **New agent…** (⌘⇧Y); every command is an action, so bind what you like:
`plugin.agents.new`, `.quick`, `.default`, `.open`, `.restart`, `.kill`, `.dup`, `.send`, …

### Quick-entry grammar

`[agent] [preset] [prompt…]`, with `@<dir>` anywhere:

| Line | Agent | Preset | Prompt | Directory |
| --- | --- | --- | --- | --- |
| `claude yolo fix the build` | claude | yolo | fix the build | focused pane's |
| `claude fix the build` | claude | its default | fix the build | focused pane's |
| `yolo fix it` | the default agent | yolo | fix it | focused pane's |
| `opus: explain this` | the default agent | opus | explain this | focused pane's |
| `codex` | codex | its default | — (terminal pane) | focused pane's |
| `claude yolo @~/dev/app read the diff` | claude | yolo | read the diff | `~/dev/app` |
| `fix the build` | the default agent | its default | fix the build | focused pane's |

A bare `@` is reported rather than taken as part of the prompt. A word is only eaten when it names a known agent, or a preset of that agent, so a prompt that starts with an ordinary word stays whole. A trailing colon (`opus:`) ends the agent/preset part explicitly, and is reported when it names nothing. `in <dir>` is deliberately **not** grammar — it would swallow the end of "fix the test in utils" — so a directory is always `@<path>`.

## Agents

A profile says how to run one CLI. The built-ins are shown only once their binary turns up on your `PATH`, which is probed through your login shell (`$SHELL -lic`, cached for 15 minutes; **Refresh detected agents** re-probes). The probe is one `command -v` per candidate, written to run under zsh, bash and fish alike.

| Agent | Binary | Presets | Initial prompt | Flags checked here |
| --- | --- | --- | --- | --- |
| Claude Code | `claude` | `claude`, `yolo`, `opus`, `haiku` | positional | yes |
| Codex | `codex` | `codex`, `yolo`, `auto` | positional | yes |
| OpenCode | `opencode` | `opencode`, `yolo` | `--prompt` | yes |
| Cursor Agent | `cursor-agent` | `cursor-agent`, `yolo` | positional | yes |
| Grok | `grok` | `grok`, `yolo` | positional | yes |
| Hermes | `hermes` | `hermes`, `yolo` | none (typed in) | yes |
| omp | `omp` | `omp` | positional | yes |
| Gemini CLI | `gemini` | `gemini`, `yolo` | `-i` | no |
| Qwen Code | `qwen` | `qwen`, `yolo` | `-i` | no |
| Aider | `aider` | `aider`, `yolo` | none (typed in) | no |
| Goose | `goose` | `goose` | none (typed in) | no |
| Amp | `amp` | `amp`, `yolo` | none (typed in) | no |
| Copilot CLI | `copilot` | `copilot`, `yolo` | none (typed in) | no |
| Crush | `crush` | `crush`, `yolo` | none (typed in) | no |

"Flags checked here" means the preset's arguments were read out of that CLI's own `--help` on a Mac on 2026-10-08. The rest come from Orca's defaults and the projects' docs, because the CLI isn't installed on this machine: `agents()` reports them as `verified = false`, and an override in `agents.json` is the fix. Notably **`codex --full-auto` does not exist in this Codex build**; the `auto` preset uses `--ask-for-approval never --sandbox danger-full-access`, and `yolo` uses `--dangerously-bypass-approvals-and-sandbox`.

## Presets

A preset is a named way to run one agent:

| Field | Meaning |
| --- | --- |
| `agent` | Which profile it runs. |
| `name` | What you type in quick entry (`yolo`). The preset's id is `<agent>:<name>`. |
| `args` | Arguments **appended** to the agent's own default args. A string is split like a shell line, or give an array. |
| `replace_args` | `true` drops the agent's default args (and the args of a whole command line), keeping only its program. |
| `command` | A whole command line, replacing the agent's binary and args entirely (this is what **Import from Orca** maps `agentCmdOverrides` to). |
| `env` | Environment variables, prefixed with `env` in front of the command. |
| `prompt` | An initial prompt the preset always sends. |
| `cwd` | A fixed directory, instead of the focused pane's. |
| `how` | Placement: `split` (default), `tab` or `replace_if_alone`. A promptless launch opens a terminal pane, where `replace_if_alone` behaves as `split`. |
| `shell` | Overrides the login-shell wrapping for this preset. |
| `prompt_delivery` | `block` (default) or `argv`; see [Prompts](#prompts-and-the-two-launch-paths). |

A launch resolves its preset as: the one you named → that agent's configured default → the global default (when it belongs to this agent) → the agent's plain preset.

## Configuration

Two layers, the second winning:

1. **`tern.kv`** — what the palette commands write (`~/Library/Application Support/Tern/plugin-data/agents/kv.json`).
2. **`agents.json`** — hand-edited, in the same directory (**Open agents.json** writes a starter and opens it).

A hand-edited entry wins over the stored one, field by field, and the palette refuses to edit it, pointing at the file instead. A malformed `agents.json` is reported (in a toast and at the top of the Agents block) and otherwise ignored, so a typo can never take the commands away.

```json
{
  "default_agent": "claude",
  "default_preset": "claude:yolo",
  "default_presets": { "codex": "codex:auto" },
  "shell": true,
  "prompt_delivery": "block",
  "remove_presets": ["claude:haiku"],
  "agents": {
    "claude": { "label": "Claude Code", "bin": "claude", "args": [], "icon": "sparkle" },
    "goose": { "env": { "GOOSE_MODE": "auto" } },
    "mycli": { "label": "My CLI", "bin": "/opt/bin/mycli", "prompt_arg": "flag:--task" }
  },
  "presets": {
    "claude:yolo": { "agent": "claude", "name": "yolo", "args": "--dangerously-skip-permissions" },
    "claude:review": {
      "agent": "claude",
      "name": "review",
      "args": "--model opus",
      "prompt": "read the diff against origin/main and tell me what will break",
      "how": "tab"
    },
    "codex:orca": {
      "agent": "codex",
      "name": "orca",
      "command": "codex -c model_reasoning_effort=\"high\" --ask-for-approval never --sandbox danger-full-access -c model_reasoning_summary=\"detailed\" -c model_supports_reasoning_summaries=true"
    }
  }
}
```

Agent profile fields: `label`, `bin`, `args`, `env`, `icon`, `command`, `shell`, `prompt_delivery`, `hidden`, plus `prompt_arg` (`positional`, `flag:<flag>` or `none`) and `title_status` (`claude`, `spinner` or `none`, the pane-title heuristic the status uses).

## The Agents block

**Agents** in the palette opens a block beside the focused pane; it is built for a sidebar (about 36–45 cells) and widens gracefully. Each launch is a native Tern `agent` row — the same element omp draws its subagents with — showing the agent and preset, the status tone, the directory and a live timer, with Focus, Restart, Duplicate, Prompt and Kill on hover. A **New agent** card below it launches each shown agent's default preset in one click. Keys: `n` new, `/` quick, `↑↓` move, `enter` focus, `r` restart, `x` kill.

A focused agent pane also gets a status-line segment (`Claude Code · yolo · working`) that opens the block when clicked.

## Prompts and the two launch paths

`cx.agents:start` requires a non-blank prompt, so what you get depends on whether there is one:

- **With a prompt** the launch is a **real Tern agent block**: pane kind `agent`, the Agent chip, visible in `cx.agents:list()`. Tern delivers the prompt itself.
- **Without one** the launch opens an ordinary **terminal pane** (`cx.layout:split`/`new_tab`) running the same command line. Everything else — the record, the status, Restart, Kill, the block — works the same; the pane just isn't kind `agent`, and the Agents block marks it `terminal`.
- **`prompt_delivery = "argv"`** puts the prompt on the agent's own command line (`claude "fix the build"`) instead. Because `start` would then deliver it a second time, such a launch is a terminal pane too. Agents whose `prompt_arg` is `none` fall back to `block` and say so in a toast.

Rejected third path: writing the `agent_command` preference, running Tern's own `new_agent_block` and putting the preference back. It races every other window, and a failure in between would leave your setting pointing at an agent you never chose.

## Status

Tern reports `idle` only for an agent that speaks its surface protocol (omp, and Hermes speaking omp's vocabulary). For everything else the plugin derives a status:

| Status | How it is known |
| --- | --- |
| `exited` / `exit N` | The pane's program ended (`PaneInfo.exited`, host `pane_exited`). |
| `working` | A spinner glyph in the pane title (braille `⠋⠙…`, clock `◐◑…`), or Claude's `✶✻✽`; else `PaneInfo.busy`. |
| `idle` | Claude Code's `✳` in the title. |
| `running` | Alive, and nothing more is known — the honest answer for codex, opencode, cursor-agent and friends. |
| `closed` | The pane is gone (the record is swept). |

Per agent: **claude** gets idle/working from its title; **codex, opencode, cursor-agent, grok, gemini, qwen, hermes** are read for a spinner, so they alternate between `working` and `running`; **aider, goose, amp, copilot, crush, omp** declare no title heuristic (`title_status = "none"`) and read as `running` while alive — for omp, Tern's own chrome already shows the real thing. Set `title_status` in `agents.json` if your CLI's title says more.

## Carly and plugin exports

```lua
await(plugins.agents.launch{agent = "claude", preset = "yolo", prompt = "read the diff", cwd = "~/dev/app"})
await(plugins.agents.presets())
await(plugins.agents.agents())
await(plugins.agents.running())
await(plugins.agents.send(pane, "and now the tests"))
```

- `launch{agent?, preset?, prompt?, cwd?, how?}` → `{pane, agent, preset, cwd, command, kind}`. `kind` is `block` (a real agent block) or `pane` (a terminal pane, when there was no prompt).
- `presets()` → every preset with its args, prompt, default flag and source.
- `agents()` → every profile with `detected`, the `path` it resolved to, its presets, `prompt_arg` and `verified`.
- `running()` → the tracked launches with `state`, `exit`, `age` and `kind`.
- `send(pane, text)` → types a follow-up prompt and Enter.

Composing with other plugins is loose and optional. [tern-worktrees](https://github.com/maxtuzz/tern-worktrees) can start an agent in a worktree it just created by calling `plugins.agents.launch{cwd = path, …}` **if** the export is there; this plugin never calls tern-worktrees, and neither depends on the other:

```lua
-- in another plugin's window half
local agents = tern.carly ~= nil and plugins ~= nil and plugins.agents or nil
if agents ~= nil then
	agents.launch({ agent = "claude", preset = "yolo", cwd = worktree, prompt = "read the diff" })
end
```

## Tern API limits

Measured on Tern 0.5.2 (details in [DESIGN.md](DESIGN.md)):

1. **`cx.agents:start` needs a non-blank prompt** (`agent command, cwd and prompt must not be blank`), hence the two launch paths above.
2. **An agent block's program does not inherit your interactive shell environment.** `claude`'s `#!/usr/bin/env node` picked Homebrew's Node instead of the nvm one on the user's PATH and the block exited 1. Every launch is therefore wrapped as `$SHELL -lic "exec <command>"`; `shell = false` (globally, per agent or per preset) opts out. The pane's `program` then reads the shell's name, which is why the plugin keeps its own record of what each pane is running.
3. **No idle, no transcript for a non-omp agent.** `AgentBlock.state` stays `working` for ever, `cx.agents:wait` times out and `cx.agents:transcript` returns `{}`. The status heuristics above are what is left.
4. **`cx.agents:ask` can't send a second prompt** to such an agent: Tern never sees a non-TSP composer report `sendable`, so it still counts the launch prompt as pending and fails with "agent already has a pending prompt". Follow-ups are typed in (`cx:run(pane, text .. "\r")`), which is what **Send prompt to agent…** and `send()` do.
5. **A window sees only its own panes** (`cx.session:panes()`), while the launch records are shared by every window, so the window half never deletes one. The host half sweeps instead — it can see every pane on the machine (`tern.pane.list()`) — when an agent exits and whenever the Agents block ticks. An ended agent stays listed for two minutes, so its exit status can be read.
6. **No plugin-settings API.** `cx.settings` covers Tern's own keys, so config lives in `tern.kv` plus `agents.json`.
7. **Writing any file inside the plugin directory triggers a plugin reload**, which cancels timers and in-flight work. The plugin only ever writes to its data directory.

## Compared with Orca

Orca's terminal agents are the model this follows: `defaultTuiAgent`, `agentCmdOverrides`, `agentDefaultArgs`, `agentDefaultEnv` and agent-prompt quick commands. **Import from Orca** reads them (read-only) and maps them to presets: a command override becomes `<agent>:orca`, yolo args become `<agent>:yolo`, env lands on the profile, and each agent-prompt quick command becomes a preset carrying its prompt. Orca installs per-agent status hooks to learn working/idle; this plugin does not touch your agents' configuration, which is why its status is read from the pane instead.

## Tests

```bash
tests/run.sh      # bundles every module (tests/bundle.py) and runs them under plain `luau`
```

72 tests, all green: config merging (kv, `agents.json`, malformed input), preset resolution, command building and shell quoting, login-shell wrapping, prompt delivery, quick-entry parsing, the editing grammars, status-from-title heuristics, Orca import, launch records and pruning, detection, both halves loading, the links the blocks answer with, the blocks themselves and the Carly exports.

## Offline docs

`docs/` mirrors the Tern plugin SDK documentation from https://docs.stencil.so/tern (Markdown form), for agents and offline reading.

## License

MIT
