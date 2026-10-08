--!strict
-- Starting an agent, and the three things that follow from a launch:
-- restart, kill and duplicate. Window half only.
--
-- Two paths, because `cx.agents:start` requires a non-blank prompt:
--
--   * With a prompt (the usual case) `start` opens a **real agent block**:
--     pane kind "agent", the Agent chip, and the launch shows up in
--     `cx.agents:list()`. Tern delivers the prompt itself.
--   * Without one — or when the agent's prompt goes on its command line
--     (`prompt_delivery = "argv"`), where `start` would deliver it twice —
--     the launch opens an ordinary **terminal pane** through `cx.layout`
--     running the same command line. Everything else works the same; the
--     pane just isn't kind "agent".
--
-- Rejected third path: setting the `agent_command` preference, running
-- Tern's own `new_agent_block` and putting the preference back. It races
-- every other window, and a failure anywhere in between would leave the
-- user's setting pointing at an agent they never chose.

local util = require("./util")
local cfg = require("./config")
local command = require("./command")
local detect = require("./detect")
local runs = require("./runs")

local launch = {}

local HOME = tern.getenv("HOME")

export type Spec = {
	agent: cfg.Agent,
	preset: cfg.Preset,
	prompt: string?,
	cwd: string?,
	how: string?,
}

export type Result = {
	pane: number,
	record: runs.Record,
	spec: command.Spec,
}

-- The focused pane's directory, when it has one.
function launch.focused_cwd(cx: WindowCx): string?
	local id = cx.session:focused()
	local info = if id then cx.session:pane(id) else nil
	if info ~= nil and info.cwd ~= nil and info.cwd ~= "" then
		return info.cwd
	end
	return nil
end

-- Where a launch runs: what the caller asked for, else the preset's own
-- directory, else the focused pane's, else any pane's, else home.
function launch.cwd_for(cx: WindowCx, spec: Spec): string
	local asked = util.clean(spec.cwd) or util.clean(spec.preset.cwd)
	local base = launch.focused_cwd(cx) or HOME or "/"
	if asked ~= nil then
		return util.resolve(base, asked, HOME)
	end
	local focused = launch.focused_cwd(cx)
	if focused ~= nil then
		return focused
	end
	for _, info in cx.session:panes() do
		if info.cwd ~= nil and info.cwd ~= "" then
			return info.cwd
		end
	end
	return HOME or "/"
end

-- Opens a terminal pane running `line`, placed like `how`.
local function open_pane(cx: WindowCx, line: string, cwd: string, how: string?): (number?, string?)
	local spec: Launch = { cwd = cwd, command = line }
	if how == "tab" then
		local pane = cx.layout:new_tab(spec)
		return pane, if pane == nil then "Tern wouldn't open a tab for it" else nil
	end
	local focused = cx.session:focused()
	if focused == nil then
		local pane = cx.layout:new_tab(spec)
		return pane, if pane == nil then "Tern wouldn't open a tab for it" else nil
	end
	local pane = cx.layout:split(focused, "right", spec)
	if pane == nil then
		return nil, "Tern wouldn't split this pane"
	end
	return pane, nil
end

-- Starts an agent. Raises a readable message when the command can't be built
-- or Tern refuses the launch.
function launch.run(cx: WindowCx, config: cfg.Config, spec: Spec): Result
	local prompt = util.clean(spec.prompt) or util.clean(spec.preset.prompt)
	local built = command.build(spec.agent, spec.preset, {
		prompt = prompt,
		shell = config.shell,
		delivery = config.prompt_delivery,
		shell_path = detect.shell(),
	})
	local cwd = launch.cwd_for(cx, spec)
	local how = spec.how or spec.preset.how or "split"

	local pane: number? = nil
	local kind = "block"
	if prompt ~= nil and not built.prompt_on_argv then
		local ok, result = pcall(function(): number
			return cx.agents:start({
				prompt = prompt :: string,
				cwd = cwd,
				command = built.line,
				how = how :: any,
			})
		end)
		if not ok then
			error("Tern wouldn't start the agent: " .. tostring(result), 0)
		end
		pane = result
	else
		kind = "pane"
		local opened, err = open_pane(cx, built.line, cwd, how)
		if opened == nil then
			error(err or "Tern wouldn't open a pane for it", 0)
		end
		pane = opened
	end

	local record: runs.Record = {
		pane = pane :: number,
		agent = spec.agent.id,
		preset = spec.preset.id,
		label = command.label(spec.agent, spec.preset),
		cwd = cwd,
		command = built.line,
		inner = built.inner,
		started_at = os.time(),
		how = how,
		kind = kind,
		prompt = prompt,
		title_status = spec.agent.title_status,
	}
	pcall(runs.put, record)
	return { pane = pane :: number, record = record, spec = built }
end

-- Launches the same agent, preset and directory again. The old pane is left
-- alone when it is still running; `close` ends it first.
function launch.restart(cx: WindowCx, config: cfg.Config, record: runs.Record, close: boolean): Result
	local agent = config.agents[record.agent]
	if agent == nil then
		error(string.format("Agent %q is no longer configured", record.agent), 0)
	end
	local preset = config.presets[record.preset]
	if preset == nil then
		error(string.format("Preset %q is no longer configured", record.preset), 0)
	end
	if close then
		launch.kill(cx, record.pane)
	end
	return launch.run(cx, config, {
		agent = agent,
		preset = preset,
		prompt = record.prompt,
		cwd = record.cwd,
		how = record.how,
	})
end

-- Closes an agent's pane: `cx.agents:stop` for an agent block (which ends
-- the program without a confirmation sheet), else the raw pane close.
function launch.kill(cx: WindowCx, pane: number)
	local info = cx.session:pane(pane)
	if info ~= nil and info.kind == "agent" then
		local ok = pcall(function()
			cx.agents:stop(pane)
		end)
		if ok then
			pcall(runs.drop, pane)
			return
		end
	end
	pcall(function()
		cx.layout:close(pane)
	end)
	pcall(runs.drop, pane)
end

-- Sends Ctrl-C to an agent without closing its block.
function launch.interrupt(cx: WindowCx, pane: number): boolean
	local ok = pcall(function()
		cx.agents:interrupt(pane)
	end)
	return ok
end

-- Types `text` into an agent's pane and presses Enter. `cx.agents:ask` can't
-- be used for a second prompt: Tern never sees a non-TSP composer report
-- `sendable`, so it still counts the launch prompt as pending and fails with
-- "agent already has a pending prompt".
function launch.send(cx: WindowCx, pane: number, text: string): boolean
	local body = util.clean(text)
	if body == nil then
		return false
	end
	local ok = pcall(function()
		cx:run(pane, body :: string .. "\r")
	end)
	return ok
end

return launch
