--!strict
-- Carly and plugin exports (desktop window only): launch an agent, list the
-- presets, the agents and what is running, and type into a running agent.
-- Everything is synchronous — `cx.agents:start`, `cx.layout` and `tern.kv`
-- all answer at once — so no call has to wait.
--
-- Another plugin can use them too: `plugins.agents.launch{...}` from Carly,
-- and `cx:action("plugin.agents.new")` for the dialogs. tern-worktrees, for
-- instance, can launch a preset in a worktree it just created:
--
--   await(plugins.agents.launch{agent = "claude", preset = "yolo",
--                               prompt = "read the diff", cwd = path})
--
-- Neither plugin depends on the other: this one never calls tern-worktrees,
-- and a worktree hook would check `plugins.agents` exists first.

local util = require("./util")
local cfg = require("./config")
local app = require("./app")
local launch = require("./launch")
local runs = require("./runs")
local model = require("./model")
local status = require("./status")
local detect = require("./detect")

local carly = {}

local LAUNCH_KEYS: { [string]: boolean } = {
	agent = true,
	preset = true,
	prompt = true,
	cwd = true,
	how = true,
}

local function optional_string(value: any, name: string): string?
	if value == nil or value == tern.json.null then
		return nil
	end
	if type(value) ~= "string" then
		error(name .. " must be a string", 0)
	end
	return util.clean(value)
end

local function launch_opts(first: any, preset: any, prompt: any, cwd: any): { [string]: string? }
	if type(first) == "table" and first ~= tern.json.null then
		if preset ~= nil or prompt ~= nil or cwd ~= nil then
			error("pass launch either one options table or positional agent, preset, prompt, cwd", 0)
		end
		for k in first do
			if not LAUNCH_KEYS[tostring(k)] then
				error(
					string.format("unknown launch option %q (agent, preset, prompt, cwd, how)", tostring(k)),
					0
				)
			end
		end
		return {
			agent = optional_string(first.agent, "agent"),
			preset = optional_string(first.preset, "preset"),
			prompt = optional_string(first.prompt, "prompt"),
			cwd = optional_string(first.cwd, "cwd"),
			how = optional_string(first.how, "how"),
		}
	end
	return {
		agent = optional_string(first, "agent"),
		preset = optional_string(preset, "preset"),
		prompt = optional_string(prompt, "prompt"),
		cwd = optional_string(cwd, "cwd"),
	}
end

function carly.register(shared: app.Shared)
	tern.carly.export("launch", {
		sig = "({agent: string?, preset: string?, prompt: string?, cwd: string?, how: string?}) -> {pane: number, agent: string, preset: string, cwd: string, command: string, kind: string}",
		doc = "Starts an agent CLI, like the palette's New agent. agent: an id from agents() (default "
			.. "the configured default). preset: an id or name from presets() (default that agent's). "
			.. "prompt: an initial prompt; with one the launch is a real Tern agent block, without one "
			.. "it is a terminal pane running the same command (agents:start requires a prompt). "
			.. "cwd: where it runs, ~ and relative paths allowed (default the focused pane's directory). "
			.. "how: split, tab or replace_if_alone. Returns the pane and what was run.",
	}, function(first: any, preset: any, prompt: any, cwd: any, cx: WindowCx, _call: ExportCall)
		local opts = launch_opts(first, preset, prompt, cwd)
		local config = app.config(nil, false)
		local agent, chosen = cfg.resolve(config, opts.agent, opts.preset, app.detected())
		local result = launch.run(cx, config, {
			agent = agent,
			preset = chosen,
			prompt = opts.prompt,
			cwd = opts.cwd,
			how = opts.how,
		})
		shared.reload()
		return {
			pane = result.pane,
			agent = agent.id,
			preset = chosen.id,
			cwd = result.record.cwd,
			command = result.record.command,
			kind = result.record.kind or "block",
		}
	end)

	tern.carly.export("presets", {
		sig = "() -> {{id: string, agent: string, name: string, args: string, prompt: string?, default: boolean, source: string}}",
		doc = "The run presets. id is what launch takes as preset; args is the argument string appended "
			.. "to the agent's own (or replacing them when the preset says so); prompt is an initial "
			.. "prompt the preset always sends; default is true for the agent's default preset; source "
			.. "is builtin, kv or agents.json.",
	}, function(_cx: WindowCx, _call: ExportCall)
		local config = app.config(nil, false)
		local rows = {}
		for _, agent in cfg.agent_list(config, nil) do
			local default = cfg.default_preset_of(config, agent.id)
			for _, preset in cfg.presets_of(config, agent.id) do
				table.insert(rows, {
					id = preset.id,
					agent = preset.agent,
					name = preset.name,
					args = util.join_args(preset.args),
					prompt = preset.prompt or tern.json.null,
					default = default ~= nil and default.id == preset.id,
					source = preset.source,
				})
			end
		end
		return tern.json.array(rows)
	end)

	tern.carly.export("agents", {
		sig = "() -> {{id: string, label: string, bin: string, path: string?, detected: boolean, presets: {string}, prompt_arg: string, verified: boolean}}",
		doc = "The configured agent profiles. detected is true when the binary was found on PATH by the "
			.. "last login-shell probe, and path is where; presets lists the names launch accepts; "
			.. "prompt_arg says how the CLI takes an initial prompt (positional, flag:<flag> or none); "
			.. "verified is true when the flags were checked against that CLI's own --help.",
	}, function(_cx: WindowCx, _call: ExportCall)
		local config = app.config(nil, false)
		local cache = detect.cached()
		local found = if cache then cache.found else {}
		local rows = {}
		for _, agent in cfg.agent_list(config, nil) do
			local names: { string } = {}
			for _, preset in cfg.presets_of(config, agent.id) do
				table.insert(names, preset.name)
			end
			table.insert(rows, {
				id = agent.id,
				label = agent.label,
				bin = agent.bin,
				path = found[agent.id] or tern.json.null,
				detected = found[agent.id] ~= nil,
				presets = tern.json.array(names),
				prompt_arg = agent.prompt_arg,
				verified = agent.verified,
			})
		end
		return tern.json.array(rows)
	end)

	tern.carly.export("running", {
		sig = "() -> {{pane: number, agent: string, preset: string, label: string, cwd: string, state: string, exit: number?, age: number, kind: string}}",
		doc = "The agents this plugin launched that are still tracked, newest first. state is working, "
			.. "idle, running (alive, nothing more known), exited or closed: Tern only reports idle for "
			.. "agents that speak its surface protocol, so for everything else it is read from the "
			.. "pane's title and exit status. age is seconds since the launch; kind is block (a real "
			.. "agent block) or pane (a terminal pane).",
	}, function(cx: WindowCx, _call: ExportCall)
		local facts: { [number]: status.PaneFacts } = {}
		for _, info in cx.session:panes() do
			facts[info.pane] = { title = info.title, busy = info.busy, exited = info.exited }
		end
		local rows = {}
		for _, row in model.rows(runs.list(), facts, os.time()) do
			table.insert(rows, {
				pane = row.pane,
				agent = row.agent,
				preset = row.preset,
				label = row.label,
				cwd = row.cwd,
				state = row.status.state,
				exit = row.status.code or tern.json.null,
				age = row.age,
				kind = row.kind,
			})
		end
		return tern.json.array(rows)
	end)

	tern.carly.export("send", {
		sig = "(pane: number, text: string) -> {pane: number, sent: string}",
		doc = "Types a prompt into a running agent's pane and presses Enter. Use this rather than "
			.. "agents:ask for an agent that isn't omp: Tern never sees such a composer report "
			.. "sendable, so ask fails with \"agent already has a pending prompt\". pane comes from "
			.. "running() or launch().",
	}, function(pane: any, text: any, cx: WindowCx, _call: ExportCall)
		if type(pane) ~= "number" then
			error("pane must be a number from running() or launch()", 0)
		end
		local body = optional_string(text, "text")
		if body == nil then
			error("text must not be blank", 0)
		end
		if not launch.send(cx, pane :: number, body :: string) then
			error("nothing was sent; is that pane still open?", 0)
		end
		return { pane = pane, sent = body }
	end)
end

return carly
