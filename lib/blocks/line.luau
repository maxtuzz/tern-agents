--!strict
-- Block `agents.line`: one text input, used by Quick agent…, the prompt
-- field, Add preset…, Add agent… and the arg editor. The window half opens it
-- with one JSON argument and gets the line back as
-- `tern-agents://line?token=…&line=…` (`cx:open`), which the window's
-- `tern.route.link` handles.
--
--   { token, title, subtitle?, value?, placeholder?, submit?,
--     hints?: [{text, tone?}], grammar?: "quick",
--     agents?: [{id, label, bin, presets: [string]}], home? }
--
-- With `grammar = "quick"` the dialog previews what the line resolves to
-- while you type. The window parses the line again against the live config,
-- so the preview is a hint, never the decision.

local util = require("../util")
local url = require("../url")
local field = require("../field")
local quick = require("../quick")

local ui = tern.ui

type Hint = { text: string, tone: string? }

type AgentHint = { id: string, label: string, bin: string?, presets: { string } }

type Ctx = {
	token: string,
	title: string,
	subtitle: string?,
	value: string?,
	placeholder: string?,
	submit: string?,
	hints: { Hint }?,
	grammar: string?,
	agents: { AgentHint }?,
	home: string?,
}

type State = { ctx: Ctx, line: field.Field, submitted: boolean }

local INPUT_ID = "main.line"

local function decode_args(args: { string }): Ctx?
	local ok, ctx = pcall(tern.json.decode, args[1] or "")
	if not ok or type(ctx) ~= "table" or type(ctx.token) ~= "string" then
		return nil
	end
	return ctx
end

local function finish(state: State, cx: BlockCx, link: string)
	state.submitted = true
	cx:open(link)
	tern.timer(1500, function()
		for _, p in tern.pane.list() do
			if p.pane == cx.pane then
				cx:exit(0)
				return
			end
		end
	end)
end

local function submit(state: State, cx: BlockCx)
	if state.submitted then
		return
	end
	finish(state, cx, url.build("line", { token = state.ctx.token, line = util.trim(state.line.text) }))
end

local function cancel(state: State, cx: BlockCx)
	if not state.submitted then
		finish(state, cx, url.build("cancel", { token = state.ctx.token }))
	end
end

local function focus_input(cx: BlockCx)
	tern.timer(30, function()
		cx:frame({ { "focus", INPUT_ID } })
	end)
end

local function row(label: string, value: string, tone: string?): { { any } }
	return { { ui.span(label, "muted") }, { ui.span(value, tone or "strong") } }
end

-- The lookups the quick grammar needs, built from the agents the window sent.
local function lookups(agents: { AgentHint }): quick.Lookup
	local by_token: { [string]: string } = {}
	local presets: { [string]: { [string]: boolean } } = {}
	for _, agent in agents do
		by_token[string.lower(agent.id)] = agent.id
		by_token[string.lower(agent.label)] = agent.id
		if agent.bin then
			by_token[string.lower(agent.bin :: string)] = agent.id
		end
		local names: { [string]: boolean } = {}
		for _, name in agent.presets do
			names[string.lower(name)] = true
		end
		presets[agent.id] = names
	end
	return {
		agent = function(token: string): string?
			return by_token[string.lower(token)]
		end,
		preset = function(agent: string, token: string): string?
			local names = presets[agent]
			if names ~= nil and names[string.lower(token)] then
				return token
			end
			return nil
		end,
		-- The dialog doesn't know the default agent; a preset-first line is
		-- previewed as a prompt and resolved for real by the window.
		default_agent = function(): string?
			return nil
		end,
	}
end

-- What the typed line resolves to, as `kv` rows.
local function preview(state: State): { Node }
	if state.ctx.grammar ~= "quick" then
		return {}
	end
	local agents = state.ctx.agents or {}
	local parsed = quick.parse(state.line.text, lookups(agents))
	if parsed.problem ~= nil then
		return { ui.text({ ui.span(parsed.problem :: string, "error") }) }
	end
	local rows = {
		row("agent", parsed.agent or "(the default)", if parsed.agent then "strong" else "muted"),
		row("preset", parsed.preset or "(its default)", if parsed.preset then "strong" else "muted"),
		row(
			"prompt",
			if parsed.prompt then util.clip(parsed.prompt :: string, 60) else "(none: opens a terminal pane)",
			if parsed.prompt then "strong" else "muted"
		),
	}
	if parsed.cwd ~= nil then
		table.insert(rows, row("in", util.resolve("/", parsed.cwd :: string, state.ctx.home)))
	end
	return { ui.kv(rows) }
end

local dialog: BlockDef<State> = {
	init = function(cx, args, saved)
		local ctx = decode_args(args)
		if ctx == nil then
			error("agents.line needs the window's launch argument; use the Agents palette commands", 0)
		end
		local start = if type(saved) == "table" and type(saved.line) == "string"
			then saved.line
			else (ctx :: Ctx).value
		focus_input(cx)
		return { ctx = ctx :: Ctx, line = field.new(start), submitted = false }
	end,

	title = function(state)
		return state.ctx.title
	end,

	view = function(state, _cx)
		local children: { Node } = {
			ui.text({
				ui.span(state.ctx.title, "strong"),
				ui.span(if state.ctx.subtitle then "  " .. (state.ctx.subtitle :: string) else "", "muted"),
			}),
			ui.node("input", {
				key = "line",
				text = state.line.text,
				cursor = state.line.cursor,
				placeholder = state.ctx.placeholder or "",
				prompt = { ui.span("› ", "muted") },
			}),
		}
		for _, hint in state.ctx.hints or {} do
			table.insert(children, ui.text({ ui.span(hint.text, hint.tone or "muted") }))
		end
		for _, node in preview(state) do
			table.insert(children, node)
		end
		local go = ui.badge(if state.submitted then "Working…" else (state.ctx.submit or "Go"), "accent")
		local gp: { [string]: any } = (go.p or {}) :: any
		gp.actions = { click = "submit" }
		go.p = gp
		local close = ui.badge("Cancel", "muted")
		local cp: { [string]: any } = (close.p or {}) :: any
		cp.actions = { click = "cancel" }
		close.p = cp
		return {
			main = ui.col(children),
			dock = ui.col({ ui.row({ go, close, ui.text({ ui.span("Enter go · Esc cancel", "muted") }) }) }),
		}
	end,

	key = function(state, key, cx)
		if state.submitted then
			return false
		end
		if key.name == "enter" then
			submit(state, cx)
		elseif key.name == "escape" then
			cancel(state, cx)
		elseif not field.key(state.line, key) then
			return false
		end
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev == "focus" then
			cx:frame({ { "focus", INPUT_ID } })
		elseif ev.ev == "action" then
			if ev.act == "submit" then
				submit(state, cx)
			elseif ev.act == "cancel" then
				cancel(state, cx)
			end
		end
	end,

	save = function(state)
		return { line = state.line.text }
	end,
}

return dialog
