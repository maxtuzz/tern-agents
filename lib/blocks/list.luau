--!strict
-- Block `agents.list`, the sidebar-friendly **Agents** block: every agent
-- this plugin launched, with its status, and a card for starting another.
--
-- It runs in the host half, which can read the launch records (`tern.kv`) and
-- every pane's title (`tern.pane.list`). Anything that changes the window —
-- focusing, restarting, killing, launching — is a window capability, so a
-- row's button opens `tern-agents://<action>?pane=…`, which the window half's
-- `tern.route.link` runs. Rows use Tern's native `agent` element, so a
-- working agent pulses here exactly as omp's subagents do.

local util = require("../util")
local url = require("../url")
local cfg = require("../config")
local runs = require("../runs")
local model = require("../model")
local status = require("../status")
local detect = require("../detect")

local ui = tern.ui

-- Pane titles and exits change without a notification the block can see, so
-- it re-reads them on a timer. Cheap: one kv stat and one pane listing.
local TICK_MS = 2000
local COMPACT_COLS = 56

type State = {
	rows: { model.Row },
	counts: model.Counts,
	presets: { { id: string, label: string, detail: string } },
	problems: { string },
	sel: number,
	timer: TimerHandle?,
	home: string?,
}

local function pane_facts(): { [number]: status.PaneFacts }
	local out: { [number]: status.PaneFacts } = {}
	local ok, panes = pcall(tern.pane.list)
	if not ok then
		return out
	end
	for _, info in panes do
		out[info.pane] = { title = info.title, busy = info.busy }
	end
	return out
end

-- The presets offered on the "New agent" card: each shown agent's default.
local function quick_presets(config: cfg.Config, detected: { [string]: boolean }): { { id: string, label: string, detail: string } }
	local out: { { id: string, label: string, detail: string } } = {}
	for _, agent in cfg.agent_list(config, detected) do
		local preset = cfg.default_preset_of(config, agent.id)
		if preset ~= nil then
			local label = if preset.name == agent.id or preset.name == agent.label
				then agent.label
				else agent.label .. " · " .. preset.name
			table.insert(out, {
				id = preset.id,
				label = label,
				detail = util.join_args(preset.args),
			})
		end
	end
	return out
end

local function refresh(state: State)
	-- The block runs in the host half, so it is allowed to sweep: the pane
	-- list it reads is the whole machine's, not one window's.
	pcall(runs.sweep)
	local records = runs.list()
	state.rows = model.rows(records, pane_facts(), os.time())
	state.counts = model.counts(state.rows)
	state.sel = math.max(1, math.min(state.sel, math.max(#state.rows, 1)))
	local ok, config = pcall(cfg.load)
	if ok then
		local live = config :: cfg.Config
		state.presets = quick_presets(live, detect.map(detect.cached()))
		state.problems = live.problems
	end
end

local function with(node: Node, props: { [string]: any }): Node
	local p: { [string]: any } = node.p or {}
	for k, v in props do
		p[k] = v
	end
	node.p = p
	return node
end

local function button(text: string, tone: string, action: string, title: string?): Node
	return with(ui.badge(text, tone), { actions = { click = action }, title = title, shrink = 0 })
end

local function row_node(state: State, row: model.Row, index: number, compact: boolean): Node
	local age = util.age(row.age)
	local where = util.tilde(row.cwd, state.home)
	local badges: { any } = { { text = row.status.label, tone = row.status.tone } }
	if row.kind ~= "block" then
		table.insert(badges, { text = "terminal", tone = "muted", title = "Launched without a prompt, so it is a terminal pane, not an agent block" })
	end
	local agent_row = ui.node("agent", {
		key = "a" .. tostring(row.pane),
		name = row.label,
		task = if compact then where else where .. "  ·  " .. age,
		status = model.element_status(row),
		badges = badges,
		stats = { age = row.age * 1000 },
		actions = { click = "focus=" .. tostring(row.pane), dblclick = "focus=" .. tostring(row.pane) },
		title = row.title or row.label,
		tone = if index == state.sel then "accent" else nil,
	})
	local controls = ui.row({
		button("Focus", "muted", "focus=" .. tostring(row.pane), "Show this agent's pane"),
		button("Restart", "muted", "restart=" .. tostring(row.pane), "Close it and start the same preset again"),
		button("Duplicate", "muted", "duplicate=" .. tostring(row.pane), "A second one, same preset and directory"),
		button("Prompt", "muted", "send=" .. tostring(row.pane), "Type a prompt into it"),
		button("Kill", "error", "kill=" .. tostring(row.pane), "Close the pane and end the program"),
	})
	return with(ui.col({ agent_row, with(controls, { key = "c", role = "agents.controls" }) }), {
		key = "r" .. tostring(row.pane),
		role = "agents.row",
	})
end

local function new_card(state: State, compact: boolean): Node
	local buttons: { Node } = {
		button("New agent…", "accent", "new", "Pick an agent, a preset and a prompt"),
		button("Quick…", "muted", "quick", "One line: claude yolo fix the build"),
	}
	for i, preset in state.presets do
		if i <= 6 then
			table.insert(
				buttons,
				button(preset.label, "info", "launch=" .. preset.id, "Launch " .. preset.id .. " " .. preset.detail)
			)
		end
	end
	local children: { Node } = { with(ui.row(buttons), { key = "b" }) }
	if #state.presets == 0 then
		table.insert(
			children,
			with(
				ui.text({ ui.span("No agents found on PATH. ", "muted"), ui.span("Refresh", "accent") }),
				{ key = "empty", actions = { click = "refresh" } }
			)
		)
	elseif not compact then
		table.insert(
			children,
			with(ui.text({ ui.span("A launch with no prompt opens a terminal pane; with one it opens an agent block.", "muted") }), { key = "note" })
		)
	end
	return with(ui.card({ ui.span("New agent", "strong") }, children), { key = "new" })
end

local function view_nodes(state: State, cols: number): { Node }
	local compact = cols > 0 and cols < COMPACT_COLS
	local counts = state.counts
	local head: { any } = { ui.span("Agents", "strong"), ui.span("  " .. tostring(counts.total), "muted num") }
	local chips: { Node } = {}
	if counts.working > 0 then
		table.insert(chips, with(ui.badge(tostring(counts.working) .. " working", "info"), { key = "w", shrink = 0 }))
	end
	if counts.idle > 0 then
		table.insert(chips, with(ui.badge(tostring(counts.idle) .. " idle", "success"), { key = "i", shrink = 0 }))
	end
	if counts.gone > 0 then
		table.insert(chips, with(ui.badge(tostring(counts.gone) .. " ended", "muted"), { key = "g", shrink = 0 }))
	end

	local rows: { Node } = {}
	for i, row in state.rows do
		table.insert(rows, row_node(state, row, i, compact))
	end
	if #rows == 0 then
		table.insert(
			rows,
			with(ui.text({ ui.span("Nothing running. Start one below.", "muted") }), { key = "none" })
		)
	end

	local out: { Node } = {}
	if #chips > 0 then
		table.insert(out, with(ui.row(chips), { key = "chips" }))
	end
	for _, problem in state.problems do
		table.insert(out, with(ui.text({ ui.span(problem, "error") }), { key = "p" .. #out }))
	end
	table.insert(out, with(ui.section(head, rows), { key = "list", role = "agents.list" }))
	table.insert(out, new_card(state, compact))
	return out
end

local function act(cx: BlockCx, action: string, value: string?)
	if action == "focus" or action == "kill" or action == "restart" or action == "duplicate" or action == "send" then
		local pane = tonumber(value)
		if pane ~= nil then
			cx:open(url.build(action, { pane = tostring(pane) }))
		end
	elseif action == "launch" then
		if value ~= nil and value ~= "" then
			cx:open(url.build("launch", { preset = value }))
		end
	elseif action == "new" or action == "quick" or action == "refresh" then
		cx:open(url.build(action, {}))
	end
end

local block: BlockDef<State> = {
	init = function(cx, _args, saved)
		local state: State = {
			rows = {},
			counts = { total = 0, working = 0, idle = 0, gone = 0 },
			presets = {},
			problems = {},
			sel = if type(saved) == "table" and type(saved.sel) == "number" then saved.sel else 1,
			timer = nil,
			home = tern.getenv("HOME"),
		}
		refresh(state)
		-- One repeating tick, rescheduled from inside: pane titles and exits
		-- are the only live status signals a non-omp agent gives. A block has
		-- no "closed" handler, so the tick stops itself once its own pane is
		-- no longer listed.
		local function alive(): boolean
			local ok, panes = pcall(tern.pane.list)
			if not ok then
				return false
			end
			for _, info in panes do
				if info.pane == cx.pane then
					return true
				end
			end
			return false
		end
		local function tick()
			state.timer = tern.timer(TICK_MS, function()
				if not alive() then
					return
				end
				refresh(state)
				cx:render()
				tick()
			end)
		end
		tick()
		return state
	end,

	title = function(state)
		local counts = state.counts
		if counts.total == 0 then
			return "Agents"
		end
		return "Agents " .. tostring(counts.total) .. (if counts.working > 0 then " ●" .. tostring(counts.working) else "")
	end,

	view = function(state, cx)
		return {
			main = ui.col(view_nodes(state, cx.cols)),
			dock = ui.col({
				ui.text({
					ui.span("n new · / quick · enter focus · r restart · x kill · ↑↓ move", "muted"),
				}),
			}),
		}
	end,

	key = function(state, key, cx)
		local name = key.name
		local row = state.rows[state.sel]
		if name == "down" or name == "j" then
			state.sel = math.min(state.sel + 1, math.max(#state.rows, 1))
		elseif name == "up" or name == "k" then
			state.sel = math.max(state.sel - 1, 1)
		elseif name == "n" then
			act(cx, "new", nil)
		elseif name == "/" then
			act(cx, "quick", nil)
		elseif name == "enter" and row ~= nil then
			act(cx, "focus", tostring(row.pane))
		elseif name == "r" and row ~= nil then
			act(cx, "restart", tostring(row.pane))
		elseif name == "x" and row ~= nil then
			act(cx, "kill", tostring(row.pane))
		elseif name == "g" then
			refresh(state)
		else
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev == "action" and type(ev.act) == "string" then
			act(cx, ev.act :: string, ev.value)
		elseif ev.ev == "focus" then
			refresh(state)
		end
	end,

	save = function(state)
		return { sel = state.sel }
	end,
}

return block
