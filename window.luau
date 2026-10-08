--!strict
-- agents, window half: the palette commands and keybindings, the
-- `tern-agents://` link route the blocks answer through, the status-line
-- segment for a focused agent pane, and the Carly exports.
--
-- Load stays small (50 ms budget): only the launch records and the status
-- heuristic are required here; the command logic, the config and the
-- launcher load on first use.

local runs = require("./lib/runs")
local status = require("./lib/status")

local IOS = tern.runtime.os == "ios"

-- Tracked launches by pane, for the status line. Reading kv is a stat, but
-- the status formatter runs on every frame, so it reads this instead.
local tracked: { [number]: runs.Record } = runs.all()

local function reload()
	tracked = runs.all()
	tern.chrome.refresh()
end

local shared = { reload = reload }

local function app()
	return require("./lib/app")
end

local function available(_cx: WindowCx): boolean
	return not IOS
end

local COMMANDS = {
	{ id = "new", title = "New agent…", icon = "plus", keys = { "cmd+shift+y" } },
	{ id = "quick", title = "Quick agent…", icon = "sparkle" },
	{ id = "default", title = "Launch default preset", icon = "play" },
	{ id = "restart", title = "Restart agent", icon = "refresh" },
	{ id = "kill", title = "Kill agent", icon = "trash" },
	{ id = "dup", title = "Duplicate agent", icon = "copy" },
	{ id = "send", title = "Send prompt to agent…", icon = "message" },
	{ id = "addpreset", title = "Add preset…", icon = "plus" },
	{ id = "editpreset", title = "Edit preset…", icon = "pen" },
	{ id = "rmpreset", title = "Remove preset…", icon = "trash" },
	{ id = "setdefault", title = "Set default preset…", icon = "star" },
	{ id = "addagent", title = "Add agent…", icon = "plus" },
	{ id = "openjson", title = "Open agents.json", icon = "file" },
	{ id = "refresh", title = "Refresh detected agents", icon = "refresh" },
	{ id = "importorca", title = "Import from Orca", icon = "download" },
}

for _, c in COMMANDS do
	local id = c.id
	tern.command({
		id = id,
		title = c.title,
		icon = c.icon,
		keys = c.keys,
		available = available,
		run = function(cx: WindowCx)
			app().run(id, cx, shared)
		end,
	})
end

-- The Agents block, from the palette and from a keybinding.
tern.command({
	id = "open",
	title = "Agents",
	icon = "sparkles",
	available = available,
	run = function(cx: WindowCx)
		if cx:new_block("agents.list", {}, "beside") == nil then
			cx:toast("error", "Agents host half isn't ready", "Run tern plugin list to see why")
		end
	end,
})

if tern.carly ~= nil and not IOS then
	require("./lib/carly").register(shared)
end

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, 14) ~= "tern-agents://" then
		return nil
	end
	return app().link(link, cx, shared)
end)

-- Panes that are gone take their records with them, so the block and the
-- status line never show a launch that isn't there.
local function prune(cx: WindowCx)
	local alive: { [number]: boolean } = {}
	for _, info in cx.session:panes() do
		alive[info.pane] = true
	end
	if runs.prune(alive) > 0 then
		reload()
	end
end

tern.on("window_start", function(cx: WindowCx)
	reload()
	prune(cx)
	-- A first probe for installed agents, so the first "New agent…" has
	-- something to offer without waiting for a shell.
	local loaded = app()
	loaded.ensure_detected(loaded.config(nil, false), nil)
end)

tern.on("pane_closed", function(ev: PaneEvent, cx: WindowCx)
	if tracked[ev.pane] ~= nil then
		prune(cx)
	end
end)

tern.on("title", function(ev: TitleEvent, _cx: WindowCx)
	-- The title is a status signal for a tracked agent, and the chrome caches
	-- its formatter results, so drop the cache when a tracked pane retitles.
	if tracked[ev.pane] ~= nil then
		tern.chrome.refresh()
	end
end)

tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
	-- A pane closed from outside this window — another window, or `tern
	-- close` — fires no `pane_closed` here, so a focus change is also when
	-- records of panes that are gone get swept.
	prune(cx)
	-- Another window (or the host half, on an exit) may have changed the
	-- records; reading them is a stat.
	local fresh = runs.all()
	local changed = false
	for pane in fresh do
		if tracked[pane] == nil then
			changed = true
		end
	end
	for pane in tracked do
		if fresh[pane] == nil then
			changed = true
		end
	end
	if changed then
		tracked = fresh
		tern.chrome.refresh()
	end
end)

-- Pure: reads only `tracked` and the pane Tern hands it.
tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local record = tracked[pane.pane]
	if record == nil then
		return nil
	end
	local state = status.of(
		{ title = pane.title, busy = pane.busy, exited = pane.exited or record.exited },
		record.title_status
	)
	return {
		{
			text = record.label .. " · " .. state.label,
			icon = "sparkles",
			tone = if state.tone == "muted" then nil else state.tone,
			command = "plugin.agents.open",
		},
	}
end)
