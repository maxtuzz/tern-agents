--!strict
-- Turning an agent profile plus a run preset into the one command line Tern
-- spawns. Pure: `build` takes everything it needs, so the tests check the
-- quoting and the shell wrapping without Tern.
--
-- Two findings shape this file (DESIGN.md has the measurements):
--
-- * An agent block's program does **not** inherit the user's interactive
--   shell environment. `claude`'s `#!/usr/bin/env node` picked the wrong Node
--   and the block exited 1. So by default the line is wrapped as
--   `<shell> -lic "exec <command>"`, which runs the user's rc files first.
--   `shell = false` on the agent, the preset or the whole config opts out.
-- * `cx.agents:start` requires a non-blank prompt and delivers it by typing
--   it into the pane. An agent whose CLI takes the prompt as an argument can
--   instead be launched with `prompt_delivery = "argv"`, which puts the
--   prompt on the command line (and, because `start` would then deliver it a
--   second time, opens a terminal pane — see lib/launch).

local util = require("./util")
local cfg = require("./config")

local command = {}

export type Spec = {
	--- The command line Tern runs.
	line: string,
	--- The line before any login-shell wrapping, for display.
	inner: string,
	--- The program, after the env prefix (`claude`, `/opt/bin/mycli`).
	program: string,
	--- Program and arguments, unquoted.
	argv: { string },
	--- Environment variables prefixed with `env`.
	env: { [string]: string },
	--- "block" (prompt typed into an agent block) or "argv".
	delivery: string,
	--- Whether the line is wrapped in a login shell.
	shell: boolean,
	--- Whether the prompt went onto the command line.
	prompt_on_argv: boolean,
	--- Why a requested `argv` delivery wasn't possible.
	note: string?,
}

export type Options = {
	prompt: string?,
	--- Login-shell default for the whole config.
	shell: boolean?,
	--- Prompt-delivery default for the whole config.
	delivery: string?,
	--- The user's shell, e.g. `/bin/zsh`.
	shell_path: string?,
}

command.DEFAULT_SHELL = "/bin/zsh"

-- The flag an agent passes its initial prompt with, or nil for a positional
-- argument; `false` when the CLI has no interactive-prompt argument.
local function prompt_flag(prompt_arg: string): (string?, boolean)
	if prompt_arg == "positional" then
		return nil, true
	end
	local flag = string.match(prompt_arg, "^flag:(.+)$")
	if flag ~= nil then
		return flag, true
	end
	return nil, false
end

-- The words a profile and preset start from: the preset's own command line,
-- else the agent's, else its binary and default args.
local function base_words(agent: cfg.Agent, preset: cfg.Preset): { string }
	if preset.command ~= nil then
		return util.split_args(preset.command)
	end
	if agent.command ~= nil then
		return util.split_args(agent.command)
	end
	local out = { agent.bin }
	for _, arg in agent.args do
		table.insert(out, arg)
	end
	return out
end

-- The command line for `agent` + `preset`. Raises when the profile names no
-- program at all.
function command.build(agent: cfg.Agent, preset: cfg.Preset, opts: Options?): Spec
	local o: Options = opts or {}
	local words = base_words(agent, preset)
	if #words == 0 or util.trim(words[1]) == "" then
		error(string.format("%s has no command to run", agent.label), 0)
	end
	-- `replace_args` keeps only the program: the agent's default args go, and
	-- so do the args of a whole command line, which is the same promise.
	local argv: { string } = if preset.replace_args then { words[1] } else table.clone(words)
	for _, arg in preset.args do
		table.insert(argv, arg)
	end

	local wanted = preset.prompt_delivery or agent.prompt_delivery or o.delivery or "block"
	local prompt = util.clean(o.prompt)
	local flag, can_argv = prompt_flag(agent.prompt_arg)
	local delivery = wanted
	local note: string? = nil
	if wanted == "argv" then
		if prompt == nil then
			delivery = "block"
		elseif not can_argv then
			delivery = "block"
			note = string.format("%s takes no prompt argument, so the prompt is typed in", agent.label)
		end
	end
	local prompt_on_argv = delivery == "argv" and prompt ~= nil
	if prompt_on_argv then
		if flag ~= nil then
			table.insert(argv, flag)
		end
		table.insert(argv, prompt :: string)
	end

	local env = util.merge(agent.env, preset.env) :: { [string]: string }
	local names: { string } = {}
	for name in env do
		table.insert(names, name)
	end
	table.sort(names)
	local parts: { string } = {}
	if #names > 0 then
		table.insert(parts, "env")
		for _, name in names do
			table.insert(parts, util.shell_quote(name .. "=" .. env[name]))
		end
	end
	table.insert(parts, util.join_args(argv))
	local inner = table.concat(parts, " ")

	-- Login-shell wrapping: the preset decides, else the agent, else the config.
	local wants_shell: boolean = true
	if preset.shell ~= nil then
		wants_shell = preset.shell :: boolean
	elseif agent.shell ~= nil then
		wants_shell = agent.shell :: boolean
	elseif o.shell ~= nil then
		wants_shell = o.shell :: boolean
	end
	local line = inner
	if wants_shell then
		local sh = util.clean(o.shell_path) or command.DEFAULT_SHELL
		line = util.shell_quote(sh) .. ' -lic "exec ' .. util.dquote_escape(inner) .. '"'
	end

	return {
		line = line,
		inner = inner,
		program = argv[1],
		argv = argv,
		env = env,
		delivery = delivery,
		shell = wants_shell,
		prompt_on_argv = prompt_on_argv,
		note = note,
	}
end

-- A short label for a launch: "Claude Code · yolo".
function command.label(agent: cfg.Agent, preset: cfg.Preset): string
	if preset.name == agent.id or preset.name == agent.label then
		return agent.label
	end
	return agent.label .. " · " .. preset.name
end

return command
