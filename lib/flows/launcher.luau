--!strict
-- The launching commands: New agent…, Quick agent…, Launch default preset,
-- Restart / Kill / Duplicate agent and Send prompt to agent….

local util = require("../util")
local cfg = require("../config")
local app = require("../app")
local quick = require("../quick")
local runs = require("../runs")
local status = require("../status")
local launch = require("../launch")

local launcher = {}

-- The agent a line that names none would use, as quick entry resolves it.
local function default_agent_id(config: cfg.Config): string?
	local agent = if config.default_agent then cfg.find_agent(config, config.default_agent) else nil
	return if agent then agent.id else nil
end

-- Every preset of every shown agent, as picker rows.
local function preset_rows(config: cfg.Config, detected: { [string]: boolean }): ({ any }, { cfg.Preset })
	local items: { any } = {}
	local presets: { cfg.Preset } = {}
	for _, agent in cfg.agent_list(config, detected) do
		local default = cfg.default_preset_of(config, agent.id)
		for _, preset in cfg.presets_of(config, agent.id) do
			table.insert(presets, preset)
			local marks: { string } = {}
			if default ~= nil and default.id == preset.id then
				table.insert(marks, "default")
			end
			if config.default_preset == preset.id then
				table.insert(marks, "global default")
			end
			local label = agent.label
			if preset.name ~= agent.id and preset.name ~= agent.label then
				label ..= " · " .. preset.name
			end
			if #marks > 0 then
				label ..= "  (" .. table.concat(marks, ", ") .. ")"
			end
			table.insert(items, {
				label = label,
				detail = app.preset_detail(config, agent, preset),
				icon = agent.icon,
				choice = tostring(#presets),
			})
		end
	end
	return items, presets
end

-- Asks for the prompt, then launches. A blank line launches without one,
-- which opens a terminal pane rather than an agent block.
local function ask_prompt(cx: WindowCx, config: cfg.Config, agent: cfg.Agent, preset: cfg.Preset, shared: app.Shared)
	local hints: { any } = {
		{ text = "Enter with no prompt opens the agent in a terminal pane: Tern's agents:start needs a prompt." },
	}
	if preset.prompt ~= nil then
		table.insert(hints, { text = "This preset's own prompt: " .. util.clip(preset.prompt :: string, 70) })
	end
	app.line(cx, {
		title = "Prompt · " .. (if preset.name == agent.id then agent.label else agent.label .. " · " .. preset.name),
		subtitle = app.tilde(launch.cwd_for(cx, { agent = agent, preset = preset })),
		placeholder = "what should it work on?",
		submit = "Launch",
		hints = hints,
	}, function(cx2, line)
		app.launch(cx2, config, { agent = agent, preset = preset, prompt = util.clean(line) }, shared)
	end)
end

-- "New agent…": pick an agent and preset, then type a prompt.
function launcher.new(cx: WindowCx, shared: app.Shared)
	local config = app.config(cx, true)
	local function offer(cx2: WindowCx)
		local detected = app.detected()
		local items, presets = preset_rows(config, detected)
		if #items == 0 then
			cx2:toast(
				"info",
				"No agents found on PATH",
				"Run \"Refresh detected agents\", or add one with \"Add agent…\""
			)
			return
		end
		app.pick(cx2, {
			title = "New agent",
			subtitle = "agent and run preset",
			notes = {
				{ text = "Detected through your login shell; " .. tostring(#items) .. " preset(s)." },
			},
			items = items,
		}, function(cx3, choice)
			local preset = presets[tonumber(choice) or 0]
			local agent = if preset then config.agents[preset.agent] else nil
			if preset == nil or agent == nil then
				return
			end
			ask_prompt(cx3, config, agent, preset, shared)
		end)
	end
	-- A first run has no probe yet; wait for one rather than offer nothing.
	if next(app.detected()) == nil then
		app.ensure_detected(config, function(cx2)
			offer(cx2 or cx)
		end)
		return
	end
	app.ensure_detected(config, nil)
	offer(cx)
end

-- "Quick agent…": one line, `claude yolo fix the build`.
function launcher.quick(cx: WindowCx, shared: app.Shared)
	local config = app.config(cx, true)
	local detected = app.detected()
	app.ensure_detected(config, nil)
	app.line(cx, {
		title = "Quick agent",
		subtitle = "[agent] [preset] [prompt…] [@dir]",
		placeholder = "claude yolo fix the build",
		submit = "Launch",
		grammar = "quick",
		agents = app.grammar(config, detected),
		default_agent = default_agent_id(config),
		cwd = launch.focused_cwd(cx),
		hints = {
			{ text = "A first word that names an agent, then one that names a preset, then the prompt." },
			{ text = "@~/dev/app runs it there; without one it uses the focused pane's directory." },
		},
	}, function(cx2, line)
		local parsed = quick.parse(line, {
			agent = function(token: string): string?
				local agent = cfg.find_agent(config, token)
				return if agent then agent.id else nil
			end,
			preset = function(agent: string, token: string): string?
				local preset = cfg.find_preset(config, agent, token)
				return if preset then preset.id else nil
			end,
			default_agent = function(): string?
				return default_agent_id(config)
			end,
		})
		if parsed.problem ~= nil then
			cx2:toast("error", "Quick agent", parsed.problem :: string)
			return
		end
		local ok, agent, preset = pcall(cfg.resolve, config, parsed.agent, parsed.preset, app.detected())
		if not ok then
			cx2:toast("error", "Quick agent", tostring(agent))
			return
		end
		app.launch(cx2, config, {
			agent = agent :: cfg.Agent,
			preset = preset :: cfg.Preset,
			prompt = parsed.prompt,
			cwd = parsed.cwd,
		}, shared)
	end)
end

-- "Launch default preset": no dialog at all, for a keybinding.
function launcher.default(cx: WindowCx, shared: app.Shared)
	local config = app.config(cx, true)
	app.ensure_detected(config, nil)
	local ok, agent, preset = pcall(cfg.resolve, config, nil, nil, app.detected())
	if not ok then
		cx:toast("error", "Agents", tostring(agent))
		return
	end
	app.launch(cx, config, { agent = agent :: cfg.Agent, preset = preset :: cfg.Preset }, shared)
end

-- The tracked agents, with the status each pane reports.
local function running_rows(cx: WindowCx): ({ any }, { runs.Record })
	local items: { any } = {}
	local records: { runs.Record } = {}
	local now = os.time()
	for _, record in runs.list() do
		local info = cx.session:pane(record.pane)
		local state = status.of(
			if info
				then { title = info.title, busy = info.busy, exited = info.exited or record.exited }
				else nil,
			record.title_status
		)
		table.insert(records, record)
		table.insert(items, {
			label = record.label,
			detail = string.format(
				"%s · %s · %s",
				state.label,
				app.tilde(record.cwd),
				util.age(now - record.started_at)
			),
			tone = state.tone,
			choice = tostring(#records),
		})
	end
	return items, records
end

-- Picks one tracked agent (immediately when there is only one), then `fn`.
local function with_agent(cx: WindowCx, title: string, fn: (WindowCx, runs.Record) -> ())
	local items, records = running_rows(cx)
	if #records == 0 then
		cx:toast("info", "No agents running", "Start one with \"New agent…\"")
		return
	end
	if #records == 1 then
		fn(cx, records[1])
		return
	end
	app.pick(cx, { title = title, subtitle = "which agent?", items = items }, function(cx2, choice)
		local record = records[tonumber(choice) or 0]
		if record ~= nil then
			fn(cx2, record)
		end
	end)
end

function launcher.restart(cx: WindowCx, shared: app.Shared)
	with_agent(cx, "Restart agent", function(cx2, record)
		local config = app.config(cx2, false)
		local ok, err = pcall(launch.restart, cx2, config, record, true)
		if not ok then
			cx2:toast("error", "Restart agent", tostring(err))
			return
		end
		cx2:toast("success", record.label, "restarted in " .. app.tilde(record.cwd))
		shared.reload()
	end)
end

function launcher.kill(cx: WindowCx, shared: app.Shared)
	with_agent(cx, "Kill agent", function(cx2, record)
		launch.kill(cx2, record.pane)
		cx2:toast("info", "Closed " .. record.label, app.tilde(record.cwd))
		shared.reload()
	end)
end

function launcher.dup(cx: WindowCx, shared: app.Shared)
	with_agent(cx, "Duplicate agent", function(cx2, record)
		local config = app.config(cx2, false)
		local ok, err = pcall(launch.restart, cx2, config, record, false)
		if not ok then
			cx2:toast("error", "Duplicate agent", tostring(err))
			return
		end
		cx2:toast("success", record.label, "a second one in " .. app.tilde(record.cwd))
		shared.reload()
	end)
end

function launcher.send(cx: WindowCx, _shared: app.Shared)
	with_agent(cx, "Send prompt", function(cx2, record)
		app.send_dialog(cx2, record)
	end)
end

return launcher
