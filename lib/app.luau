--!strict
-- The window half's shared logic, loaded on first use so `window.luau` stays
-- small: the live config, the dialog blocks (and the one-shot tokens they
-- answer through), the `tern-agents://` routes the Agents block's rows use,
-- and the palette dispatch.

local util = require("./util")
local url = require("./url")
local cfg = require("./config")
local detect = require("./detect")
local runs = require("./runs")
local launch = require("./launch")
local command = require("./command")

local app = {}

local HOME = tern.getenv("HOME")
local TOKEN_TTL_MS = 30 * 60 * 1000

export type Shared = {
	--- Re-reads the launch records and redraws the chrome.
	reload: () -> (),
}

-- The actions our dialog blocks answer with, so a link whose token has
-- expired can be told apart from a row's action.
local DIALOG_ACTIONS: { [string]: boolean } = { pick = true, line = true }

type Handler = (cx: WindowCx, action: string, params: { [string]: string }) -> ()
local pending: { [string]: { at: number, on: Handler } } = {}
local seq = 0
math.randomseed(math.floor((os.time() * 1000 + tern.now()) % 2147483647))

-- A one-shot token whose link runs `on`.
function app.token(on: Handler): string
	seq += 1
	local now = tern.now()
	for t, p in pending do
		if now - p.at > TOKEN_TTL_MS then
			pending[t] = nil
		end
	end
	local t = string.format("%x%x%x", seq, math.random(0, 0x7fffffff), math.floor(now))
	pending[t] = { at = now, on = on }
	return t
end

function app.tilde(path: string?): string
	return util.tilde(path or "", HOME)
end

-- The live config. With `notify`, complaints about the stored config or the
-- hand-edited file are toasted once, here, where the user asked for
-- something.
function app.config(cx: WindowCx?, notify: boolean?): cfg.Config
	local config = cfg.load()
	if notify and cx ~= nil and #config.problems > 0 then
		cx:toast("error", "Agents config", table.concat(config.problems, " · "))
	end
	return config
end

-- Agent ids found on PATH by the last probe.
function app.detected(): { [string]: boolean }
	return detect.map(detect.cached())
end

-- Probes for agent binaries when the cache is old, then `cb`.
function app.ensure_detected(config: cfg.Config, cb: ((WindowCx?) -> ())?)
	local cache = detect.cached()
	if not detect.stale(cache) then
		if cb then
			cb(nil)
		end
		return
	end
	detect.refresh(detect.candidates(config.agents :: any), function(_cache, _err, cx)
		if cb then
			cb(cx)
		end
	end)
end

-- Opens the `pick` block listing `items`; `on_choice(cx, choice)` runs for
-- the chosen row.
function app.pick(
	cx: WindowCx,
	spec: { title: string, subtitle: string?, notes: { any }?, items: { any } },
	on_choice: (WindowCx, string) -> ()
)
	local token = app.token(function(cx2, action, params)
		if action == "pick" and params.choice then
			on_choice(cx2, params.choice)
		end
	end)
	local arg = tern.json.encode({
		token = token,
		title = spec.title,
		subtitle = spec.subtitle,
		notes = tern.json.array(spec.notes or {}),
		items = tern.json.array(spec.items),
	})
	if cx:new_block("agents.pick", { arg }, "below") == nil then
		pending[token] = nil
		cx:toast("error", "Agents host half isn't ready", "Run tern plugin list to see why")
	end
end

-- Opens the one-line dialog; `on_line(cx, line)` runs on submit.
function app.line(
	cx: WindowCx,
	spec: {
		title: string,
		subtitle: string?,
		value: string?,
		placeholder: string?,
		submit: string?,
		hints: { any }?,
		grammar: string?,
		agents: { any }?,
	},
	on_line: (WindowCx, string) -> ()
)
	local token = app.token(function(cx2, _action, params)
		if params.line ~= nil then
			on_line(cx2, params.line)
		end
	end)
	local arg: { [string]: any } = {
		token = token,
		title = spec.title,
		subtitle = spec.subtitle,
		value = spec.value,
		placeholder = spec.placeholder,
		submit = spec.submit,
		grammar = spec.grammar,
		home = HOME,
		hints = tern.json.array(spec.hints or {}),
		agents = tern.json.array(spec.agents or {}),
	}
	if cx:new_block("agents.line", { tern.json.encode(arg) }, "below") == nil then
		pending[token] = nil
		cx:toast("error", "Agents host half isn't ready", "Run tern plugin list to see why")
	end
end

-- What the quick-entry dialog needs to preview a line: every shown agent
-- with its presets.
function app.grammar(config: cfg.Config, detected: { [string]: boolean }?): { any }
	local out: { any } = {}
	for _, agent in cfg.agent_list(config, detected) do
		local presets: { string } = {}
		for _, preset in cfg.presets_of(config, agent.id) do
			table.insert(presets, preset.name)
		end
		table.insert(out, {
			id = agent.id,
			label = agent.label,
			bin = agent.bin,
			presets = tern.json.array(presets),
		})
	end
	return out
end

-- Launches `agent`/`preset`, toasting what happened either way.
function app.launch(
	cx: WindowCx,
	config: cfg.Config,
	spec: launch.Spec,
	shared: Shared?
): number?
	local ok, result = pcall(launch.run, cx, config, spec)
	if not ok then
		cx:toast("error", "Agents", tostring(result))
		return nil
	end
	local launched = result :: launch.Result
	local where = app.tilde(launched.record.cwd)
	local how = if launched.record.kind == "block" then "agent block" else "terminal pane"
	if launched.spec.note ~= nil then
		cx:toast("info", launched.record.label, (launched.spec.note :: string) .. " · " .. where)
	else
		cx:toast("success", launched.record.label, how .. " · " .. where)
	end
	if shared then
		shared.reload()
	end
	return launched.pane
end

-- The record a `pane=` parameter names, or nil with a toast.
local function record_of(cx: WindowCx, params: { [string]: string }): runs.Record?
	local pane = tonumber(params.pane)
	local record = if pane then runs.get(pane :: number) else nil
	if record == nil then
		cx:toast("error", "Agents", "That agent is no longer tracked")
		return nil
	end
	return record
end

-- A row's action from the Agents block, or a dialog's answer.
local function act(cx: WindowCx, action: string, params: { [string]: string }, shared: Shared)
	if action == "focus" then
		local pane = tonumber(params.pane)
		if pane ~= nil then
			pcall(function()
				cx.layout:focus(pane :: number)
			end)
		end
	elseif action == "kill" then
		local record = record_of(cx, params)
		if record ~= nil then
			launch.kill(cx, record.pane)
			cx:toast("info", "Closed " .. record.label, app.tilde(record.cwd))
			shared.reload()
		end
	elseif action == "interrupt" then
		local record = record_of(cx, params)
		if record ~= nil and launch.interrupt(cx, record.pane) then
			cx:toast("info", "Interrupted " .. record.label, "Ctrl-C sent")
		end
	elseif action == "restart" or action == "duplicate" then
		local record = record_of(cx, params)
		if record ~= nil then
			local config = app.config(cx, false)
			local ok, err = pcall(launch.restart, cx, config, record, action == "restart")
			if not ok then
				cx:toast("error", "Agents", tostring(err))
			else
				cx:toast("success", record.label, if action == "restart" then "restarted" else "duplicated")
				shared.reload()
			end
		end
	elseif action == "send" then
		local record = record_of(cx, params)
		if record ~= nil then
			app.send_dialog(cx, record)
		end
	elseif action == "launch" then
		local config = app.config(cx, false)
		local preset = config.presets[params.preset or ""]
		local agent = if preset then config.agents[preset.agent] else nil
		if preset == nil or agent == nil then
			cx:toast("error", "Agents", "That preset is gone; pick another")
			return
		end
		app.launch(cx, config, {
			agent = agent,
			preset = preset,
			prompt = util.clean(params.prompt),
			cwd = util.clean(params.cwd),
			how = util.clean(params.how),
		}, shared)
	elseif action == "new" or action == "quick" or action == "refresh" then
		app.run(action, cx, shared)
	end
end

-- "Send prompt to agent…" for one tracked agent.
function app.send_dialog(cx: WindowCx, record: runs.Record)
	app.line(cx, {
		title = "Prompt · " .. record.label,
		subtitle = app.tilde(record.cwd),
		placeholder = "what should it do next?",
		submit = "Send",
		hints = {
			{
				text = "Typed into the pane: Tern's agents:ask refuses a second prompt for a non-omp agent.",
			},
		},
	}, function(cx2, line)
		if launch.send(cx2, record.pane, line) then
			cx2:toast("success", "Sent to " .. record.label, util.clip(util.trim(line), 60))
		else
			cx2:toast("error", "Agents", "Nothing was sent")
		end
	end)
end

-- Closes the dialog block a link came from (only our own blocks).
local function close_block(cx: WindowCx, pane: number?)
	if pane == nil then
		return
	end
	local info = cx.session:pane(pane)
	if
		info ~= nil
		and info.kind == "plugin"
		and type(info.block) == "string"
		and string.find(info.block :: string, "agents.", 1, true) ~= nil
	then
		pcall(function()
			cx.layout:close(pane)
		end)
	end
end

-- `tern.route.link` for `tern-agents://…`.
function app.link(link: LinkRequest, cx: WindowCx, shared: Shared): RouteDecision?
	local action, params = url.parse(link.url)
	if action == nil then
		return nil
	end
	local token = params.token
	if token ~= nil then
		close_block(cx, link.pane)
		local p = pending[token]
		if p == nil then
			if DIALOG_ACTIONS[action] then
				cx:toast("error", "That dialog has expired", "Run the command again (a plugin reload closes open dialogs)")
			end
			return { handled = true }
		end
		pending[token] = nil
		if action ~= "cancel" then
			p.on(cx, action, params)
		end
		return { handled = true }
	end
	act(cx, action, params, shared)
	return { handled = true }
end

-- Runs palette command `id`.
function app.run(id: string, cx: WindowCx, shared: Shared)
	if id == "new" or id == "quick" or id == "default" or id == "restart" or id == "kill" or id == "dup" or id == "send" then
		(require("./flows/launcher") :: any)[id](cx, shared)
	else
		(require("./flows/manage") :: any)[id](cx, shared)
	end
end

-- A one-line description of what a preset will run, for pickers and previews.
function app.preset_detail(config: cfg.Config, agent: cfg.Agent, preset: cfg.Preset): string
	local ok, built = pcall(command.build, agent, preset, {
		shell = config.shell,
		delivery = config.prompt_delivery,
		shell_path = detect.shell(),
	})
	if not ok then
		return tostring(built)
	end
	local spec = built :: command.Spec
	local bits = { spec.inner }
	if preset.prompt ~= nil then
		table.insert(bits, "prompt: " .. util.clip(preset.prompt :: string, 40))
	end
	if preset.cwd ~= nil then
		table.insert(bits, "in " .. app.tilde(preset.cwd))
	end
	return table.concat(bits, " · ")
end

return app
