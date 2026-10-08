--!strict
-- The built-in agent profiles and run presets. Pure data plus two accessors,
-- so the tests read exactly what the plugin ships.
--
-- `prompt_arg` says how an initial prompt can be passed on the command line:
--   "positional"   `claude "fix the build"`
--   "flag:<flag>"  `opencode --prompt "fix the build"`
--   "none"         the CLI has no interactive-prompt argument
-- It matters only for `prompt_delivery = "argv"` launches (see lib/command).
-- Entries marked `verified = false` could not be checked on this machine
-- (the CLI isn't installed); their flags come from Orca's defaults and the
-- projects' own documentation, and a user override is the fix.
--
-- `title_status` names the heuristic that reads the pane title (lib/status):
--   "claude"   `✳` idle, spinner glyphs working
--   "spinner"  spinner glyphs working, anything else unknown
--   "none"     the title says nothing about progress

local catalog = {}

export type AgentSpec = {
	id: string,
	label: string,
	bin: string,
	args: { string },
	env: { [string]: string },
	icon: string,
	prompt_arg: string,
	title_status: string,
	verified: boolean,
	note: string?,
}

export type PresetSpec = {
	id: string,
	name: string,
	agent: string,
	args: { string },
	replace_args: boolean?,
	env: { [string]: string }?,
	prompt: string?,
	how: string?,
	builtin: boolean?,
}

-- Checked against `--help` on a Mac on 2026-10-08 where `verified` is true.
local AGENTS: { AgentSpec } = {
	{
		id = "claude",
		label = "Claude Code",
		bin = "claude",
		args = {},
		env = {},
		icon = "sparkle",
		prompt_arg = "positional",
		title_status = "claude",
		verified = true,
	},
	{
		id = "codex",
		label = "Codex",
		bin = "codex",
		args = {},
		env = {},
		icon = "code",
		prompt_arg = "positional",
		title_status = "spinner",
		verified = true,
	},
	{
		id = "opencode",
		label = "OpenCode",
		bin = "opencode",
		args = {},
		env = {},
		icon = "terminal",
		prompt_arg = "flag:--prompt",
		title_status = "spinner",
		verified = true,
	},
	{
		id = "cursor-agent",
		label = "Cursor Agent",
		bin = "cursor-agent",
		args = {},
		env = {},
		icon = "cursor",
		prompt_arg = "positional",
		title_status = "spinner",
		verified = true,
	},
	{
		id = "grok",
		label = "Grok",
		bin = "grok",
		args = {},
		env = {},
		icon = "sparkle",
		prompt_arg = "positional",
		title_status = "spinner",
		verified = true,
	},
	{
		id = "hermes",
		label = "Hermes",
		bin = "hermes",
		args = {},
		env = {},
		icon = "sparkle",
		prompt_arg = "none",
		title_status = "spinner",
		verified = true,
		note = "hermes -z is one-shot, not an interactive prompt, so prompts are typed in.",
	},
	{
		id = "omp",
		label = "omp",
		bin = "omp",
		args = {},
		env = {},
		icon = "sparkle",
		prompt_arg = "positional",
		title_status = "none",
		verified = true,
		note = "Tern's own agent: it speaks TSP, so Tern draws its chat and reports idle itself.",
	},
	{
		id = "gemini",
		label = "Gemini CLI",
		bin = "gemini",
		args = {},
		env = {},
		icon = "sparkle",
		prompt_arg = "flag:-i",
		title_status = "spinner",
		verified = false,
	},
	{
		id = "qwen",
		label = "Qwen Code",
		bin = "qwen",
		args = {},
		env = {},
		icon = "sparkle",
		prompt_arg = "flag:-i",
		title_status = "spinner",
		verified = false,
	},
	{
		id = "aider",
		label = "Aider",
		bin = "aider",
		args = {},
		env = {},
		icon = "pen",
		prompt_arg = "none",
		title_status = "none",
		verified = false,
		note = "aider --message is one-shot, so prompts are typed in.",
	},
	{
		id = "goose",
		label = "Goose",
		bin = "goose",
		args = {},
		env = { GOOSE_MODE = "auto" },
		icon = "sparkle",
		prompt_arg = "none",
		title_status = "none",
		verified = false,
	},
	{
		id = "amp",
		label = "Amp",
		bin = "amp",
		args = {},
		env = {},
		icon = "sparkle",
		prompt_arg = "none",
		title_status = "none",
		verified = false,
	},
	{
		id = "copilot",
		label = "Copilot CLI",
		bin = "copilot",
		args = {},
		env = {},
		icon = "sparkle",
		prompt_arg = "none",
		title_status = "none",
		verified = false,
	},
	{
		id = "crush",
		label = "Crush",
		bin = "crush",
		args = {},
		env = {},
		icon = "sparkle",
		prompt_arg = "none",
		title_status = "none",
		verified = false,
	},
}

-- `<agent>:<preset>` ids. The plain preset of each agent is its own id, so
-- "claude" is the agent and `claude:claude` its no-extra-arguments preset.
local PRESETS: { PresetSpec } = {
	{ id = "claude:claude", name = "claude", agent = "claude", args = {} },
	{ id = "claude:yolo", name = "yolo", agent = "claude", args = { "--dangerously-skip-permissions" } },
	{ id = "claude:opus", name = "opus", agent = "claude", args = { "--model", "opus" } },
	{ id = "claude:haiku", name = "haiku", agent = "claude", args = { "--model", "haiku" } },
	{ id = "codex:codex", name = "codex", agent = "codex", args = {} },
	{
		id = "codex:yolo",
		name = "yolo",
		agent = "codex",
		args = { "--dangerously-bypass-approvals-and-sandbox" },
	},
	{
		id = "codex:auto",
		name = "auto",
		agent = "codex",
		args = { "--ask-for-approval", "never", "--sandbox", "danger-full-access" },
	},
	{ id = "opencode:opencode", name = "opencode", agent = "opencode", args = {} },
	{ id = "opencode:yolo", name = "yolo", agent = "opencode", args = { "--auto" } },
	{ id = "cursor-agent:cursor-agent", name = "cursor-agent", agent = "cursor-agent", args = {} },
	{ id = "cursor-agent:yolo", name = "yolo", agent = "cursor-agent", args = { "--force" } },
	{ id = "grok:grok", name = "grok", agent = "grok", args = {} },
	{ id = "grok:yolo", name = "yolo", agent = "grok", args = { "--always-approve" } },
	{ id = "hermes:hermes", name = "hermes", agent = "hermes", args = {} },
	{ id = "hermes:yolo", name = "yolo", agent = "hermes", args = { "--yolo" } },
	{ id = "omp:omp", name = "omp", agent = "omp", args = {} },
	{ id = "gemini:gemini", name = "gemini", agent = "gemini", args = {} },
	{ id = "gemini:yolo", name = "yolo", agent = "gemini", args = { "--yolo" } },
	{ id = "qwen:qwen", name = "qwen", agent = "qwen", args = {} },
	{ id = "qwen:yolo", name = "yolo", agent = "qwen", args = { "--approval-mode", "yolo" } },
	{ id = "aider:aider", name = "aider", agent = "aider", args = {} },
	{ id = "aider:yolo", name = "yolo", agent = "aider", args = { "--yes-always" } },
	{ id = "goose:goose", name = "goose", agent = "goose", args = {} },
	{ id = "amp:amp", name = "amp", agent = "amp", args = {} },
	{ id = "amp:yolo", name = "yolo", agent = "amp", args = { "--dangerously-allow-all" } },
	{ id = "copilot:copilot", name = "copilot", agent = "copilot", args = {} },
	{ id = "copilot:yolo", name = "yolo", agent = "copilot", args = { "--yolo" } },
	{ id = "crush:crush", name = "crush", agent = "crush", args = {} },
	{ id = "crush:yolo", name = "yolo", agent = "crush", args = { "--yolo" } },
}

-- The built-in agent profiles, by id. Fresh tables, so a caller can't change
-- what the next call returns.
function catalog.agents(): { [string]: AgentSpec }
	local out: { [string]: AgentSpec } = {}
	for _, spec in AGENTS do
		out[spec.id] = {
			id = spec.id,
			label = spec.label,
			bin = spec.bin,
			args = table.clone(spec.args),
			env = table.clone(spec.env),
			icon = spec.icon,
			prompt_arg = spec.prompt_arg,
			title_status = spec.title_status,
			verified = spec.verified,
			note = spec.note,
		}
	end
	return out
end

-- The built-in presets, by id.
function catalog.presets(): { [string]: PresetSpec }
	local out: { [string]: PresetSpec } = {}
	for _, spec in PRESETS do
		out[spec.id] = {
			id = spec.id,
			name = spec.name,
			agent = spec.agent,
			args = table.clone(spec.args),
			builtin = true,
		}
	end
	return out
end

-- The order the built-ins are listed in, for stable pickers.
function catalog.order(): { string }
	local out: { string } = {}
	for _, spec in AGENTS do
		table.insert(out, spec.id)
	end
	return out
end

return catalog
