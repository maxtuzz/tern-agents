--!strict
-- The config commands: Add / Edit / Remove preset…, Set default preset…,
-- Add agent…, Open agents.json, Refresh detected agents, Import from Orca.
--
-- They all write the `tern.kv` layer. The hand-edited `agents.json` wins over
-- it, so a command that would be overruled by the file refuses and says so
-- rather than writing something the user won't see take effect.

local util = require("../util")
local cfg = require("../config")
local app = require("../app")
local forms = require("../forms")
local detect = require("../detect")
local orca = require("../orca")

local manage = {}

local STARTER = [[{
  "$comment": "Hand-edited agent profiles and run presets; these win over the palette's own entries.",
  "default_agent": "claude",
  "default_presets": { "claude": "claude:yolo" },
  "prompt_delivery": "block",
  "shell": true,
  "agents": {
    "claude": { "label": "Claude Code", "bin": "claude" }
  },
  "presets": {
    "claude:yolo": { "agent": "claude", "name": "yolo", "args": "--dangerously-skip-permissions" }
  }
}
]]

-- Rows for every preset, with the agent it belongs to.
local function preset_rows(config: cfg.Config): ({ any }, { cfg.Preset })
	local items: { any } = {}
	local presets: { cfg.Preset } = {}
	for _, agent in cfg.agent_list(config, nil) do
		for _, preset in cfg.presets_of(config, agent.id) do
			table.insert(presets, preset)
			local source = if preset.source == "builtin"
				then "built in"
				else (if preset.source == "kv" then "yours" else preset.source)
			table.insert(items, {
				label = agent.label .. " · " .. preset.name,
				detail = app.preset_detail(config, agent, preset) .. "  [" .. source .. "]",
				icon = agent.icon,
				choice = tostring(#presets),
			})
		end
	end
	return items, presets
end

local function declared_refusal(cx: WindowCx, what: string, source: string): boolean
	if source ~= cfg.FILE then
		return false
	end
	cx:toast("error", what, "It is declared in " .. cfg.FILE .. "; change it there")
	return true
end

-- Writes one preset into the kv layer. A preset of this id that "Remove
-- preset…" had hidden comes back: otherwise the removal would keep cancelling
-- the entry, and the command would report a success nothing could see.
local function store_preset(agent_id: string, name: string, fields: { [string]: any }): string
	local id = agent_id .. ":" .. util.slug(name)
	local store = cfg.patch("presets", id, util.merge({ agent = agent_id, name = name }, fields))
	local hidden = util.string_list(store.remove_presets)
	local at = table.find(hidden, id)
	if at ~= nil then
		local kept: { string } = {}
		for i, other in hidden do
			if i ~= at then
				table.insert(kept, other)
			end
		end
		local out = table.clone(store)
		out.remove_presets = tern.json.array(kept)
		cfg.save(out)
	end
	return id
end

-- "Add preset…": `<agent> <name> [args…]`.
function manage.addpreset(cx: WindowCx, _shared: app.Shared)
	local config = app.config(cx, true)
	app.line(cx, {
		title = "Add preset",
		subtitle = "<agent> <name> [args…]",
		placeholder = "claude yolo --dangerously-skip-permissions",
		submit = "Add",
		hints = {
			{ text = "The args are appended to the agent's own; " .. cfg.FILE .. " has the full schema (env, prompt, cwd, placement)." },
		},
	}, function(cx2, line)
		local parsed = forms.parse_preset(line, function(token: string): boolean
			return cfg.find_agent(config, token) ~= nil
		end)
		if parsed.problem ~= nil then
			cx2:toast("error", "Add preset", parsed.problem :: string)
			return
		end
		if parsed.agent == nil or parsed.name == nil then
			cx2:toast("error", "Add preset", "Type an agent and a name")
			return
		end
		local agent = cfg.find_agent(config, parsed.agent) :: cfg.Agent
		local existing = cfg.find_preset(config, agent.id, parsed.name)
		if existing ~= nil and declared_refusal(cx2, "Add preset", existing.source) then
			return
		end
		local id = store_preset(agent.id, parsed.name :: string, { args = tern.json.array(parsed.args) })
		cx2:toast("success", "Added " .. id, util.join_args(parsed.args))
	end)
end

-- "Edit preset…": pick one, then retype its args.
function manage.editpreset(cx: WindowCx, _shared: app.Shared)
	local config = app.config(cx, true)
	local items, presets = preset_rows(config)
	if #presets == 0 then
		cx:toast("info", "No presets", "Add one with \"Add preset…\"")
		return
	end
	app.pick(cx, { title = "Edit preset", subtitle = "its arguments", items = items }, function(cx2, choice)
		local preset = presets[tonumber(choice) or 0]
		if preset == nil or declared_refusal(cx2, "Edit preset", preset.source) then
			return
		end
		local agent = config.agents[preset.agent]
		app.line(cx2, {
			title = "Args · " .. (if agent then agent.label else preset.agent) .. " · " .. preset.name,
			subtitle = "appended to the agent's own args",
			value = util.join_args(preset.args),
			placeholder = "--model opus",
			submit = "Save",
			hints = {
				{ text = "A blank line gives the preset no extra args." },
				{ text = "For env, an initial prompt, a directory or placement, edit " .. cfg.FILE .. "." },
			},
		}, function(cx3, edited)
			local args = util.split_args(edited)
			store_preset(preset.agent, preset.name, { args = tern.json.array(args) })
			cx3:toast("success", "Saved " .. preset.id, if #args > 0 then util.join_args(args) else "no extra args")
		end)
	end)
end

-- "Remove preset…": drops a stored preset, or hides a built-in one.
function manage.rmpreset(cx: WindowCx, _shared: app.Shared)
	local config = app.config(cx, true)
	local items, presets = preset_rows(config)
	if #presets == 0 then
		cx:toast("info", "No presets", "Add one with \"Add preset…\"")
		return
	end
	app.pick(cx, { title = "Remove preset", subtitle = "built-in ones are hidden, not deleted", items = items }, function(cx2, choice)
		local preset = presets[tonumber(choice) or 0]
		if preset == nil or declared_refusal(cx2, "Remove preset", preset.source) then
			return
		end
		local store = cfg.stored()
		local stored_presets: { [string]: any } = if type(store.presets) == "table" then table.clone(store.presets) else {}
		stored_presets[preset.id] = nil
		local hidden: { string } = util.string_list(store.remove_presets)
		if preset.builtin and table.find(hidden, preset.id) == nil then
			table.insert(hidden, preset.id)
		end
		local out = table.clone(store)
		out.presets = stored_presets
		out.remove_presets = tern.json.array(hidden)
		if out.default_preset == preset.id then
			out.default_preset = nil
		end
		cfg.save(out)
		cx2:toast("success", "Removed " .. preset.id, if preset.builtin then "built-in preset hidden" else "")
	end)
end

-- "Set default preset…": for its own agent, or for everything.
function manage.setdefault(cx: WindowCx, _shared: app.Shared)
	local config = app.config(cx, true)
	local items, presets = preset_rows(config)
	if #presets == 0 then
		cx:toast("info", "No presets", "Add one with \"Add preset…\"")
		return
	end
	app.pick(cx, { title = "Set default preset", subtitle = "which preset?", items = items }, function(cx2, choice)
		local preset = presets[tonumber(choice) or 0]
		if preset == nil then
			return
		end
		local agent = config.agents[preset.agent]
		local label = (if agent then agent.label else preset.agent) .. " · " .. preset.name
		app.pick(cx2, {
			title = "Default for…",
			subtitle = label,
			items = {
				{
					label = "This agent",
					detail = "what " .. (if agent then agent.label else preset.agent) .. " launches when no preset is named",
					choice = "agent",
				},
				{
					label = "Everything",
					detail = "also the default agent, so \"Launch default preset\" uses it",
					choice = "global",
				},
			},
		}, function(cx3, scope)
			local store = cfg.stored()
			local out = table.clone(store)
			local defaults: { [string]: any } = if type(store.default_presets) == "table"
				then table.clone(store.default_presets)
				else {}
			defaults[preset.agent] = preset.id
			out.default_presets = defaults
			if scope == "global" then
				out.default_preset = preset.id
				out.default_agent = preset.agent
			end
			cfg.save(out)
			cx3:toast(
				"success",
				"Default: " .. label,
				if scope == "global" then "for every launch" else "for " .. preset.agent
			)
		end)
	end)
end

-- "Add agent…": `<id> [binary] [args…]`.
function manage.addagent(cx: WindowCx, _shared: app.Shared)
	local config = app.config(cx, true)
	app.line(cx, {
		title = "Add agent",
		subtitle = "<id> [binary] [args…]",
		placeholder = "mycli /opt/bin/mycli --quiet",
		submit = "Add",
		hints = {
			{ text = "The binary defaults to the id and is looked up in your login shell's PATH." },
			{ text = "Set prompt_arg, env, icon or a whole command line in " .. cfg.FILE .. "." },
		},
	}, function(cx2, line)
		local parsed = forms.parse_agent(line)
		if parsed.problem ~= nil then
			cx2:toast("error", "Add agent", parsed.problem :: string)
			return
		end
		if parsed.id == nil then
			cx2:toast("error", "Add agent", "Type an id")
			return
		end
		local id = parsed.id :: string
		local existing = config.agents[id]
		if existing ~= nil and declared_refusal(cx2, "Add agent", existing.source) then
			return
		end
		local entry: { [string]: any } = { id = id, bin = parsed.bin or id, args = tern.json.array(parsed.args) }
		if existing == nil then
			entry.label = id
		end
		cfg.patch("agents", id, entry)
		-- An agent with no preset can't be launched; give it its plain one.
		if cfg.find_preset(config, id, id) == nil then
			store_preset(id, id, { args = tern.json.array({}) })
		end
		detect.refresh(detect.candidates(cfg.load().agents :: any), function(_cache, _err, cx3)
			local shown = cx3 or cx2
			local found = app.detected()[id] == true
			shown:toast(
				if found then "success" else "info",
				"Added " .. id,
				if found then "found on PATH" else (parsed.bin or id) .. " isn't on PATH yet"
			)
		end)
	end)
end

-- "Open agents.json": writes a starter file the first time, then opens it.
function manage.openjson(cx: WindowCx, _shared: app.Shared)
	local path = cfg.path()
	if not tern.fs.exists(path) then
		local ok, err = pcall(function()
			tern.fs.mkdir(tern.plugin.data)
			tern.fs.write(path, STARTER)
		end)
		if not ok then
			cx:toast("error", "Agents", "Couldn't write " .. path .. ": " .. tostring(err))
			return
		end
		cx:toast("info", "Created " .. cfg.FILE, app.tilde(path))
	end
	cx:open(path, "beside")
end

-- "Refresh detected agents": probes PATH again through the login shell.
function manage.refresh(cx: WindowCx, shared: app.Shared)
	local config = app.config(cx, true)
	cx:toast("info", "Agents", "Asking " .. detect.shell() .. " what's installed…")
	detect.refresh(detect.candidates(config.agents :: any), function(cache, err, cx2)
		-- A probe that couldn't even start answers on this call stack, with no
		-- `cx` of its own, so the command's own one is still valid there.
		local shown = cx2 or cx
		if cache == nil then
			shown:toast("error", "Agents", err or "the probe failed")
			return
		end
		local names: { string } = {}
		for id in cache.found do
			table.insert(names, id)
		end
		table.sort(names)
		shared.reload()
		shown:toast(
			"success",
			tostring(#names) .. " agent(s) found",
			if #names > 0 then table.concat(names, ", ") else "nothing on PATH"
		)
	end)
end

-- "Import from Orca": copies Orca's command overrides, yolo args, env and
-- agent-prompt quick commands into the kv layer. Read-only on Orca's side.
function manage.importorca(cx: WindowCx, shared: app.Shared)
	local home = tern.getenv("HOME")
	local path = orca.path(home)
	local layer, problem = orca.read(path)
	if problem ~= nil then
		cx:toast("error", "Import from Orca", problem :: string)
		return
	end
	if next(layer) == nil then
		cx:toast("info", "Import from Orca", "No agent settings at " .. app.tilde(path))
		return
	end
	local store = cfg.stored()
	local out = table.clone(store)
	local agents: { [string]: any } = if type(store.agents) == "table" then table.clone(store.agents) else {}
	local presets: { [string]: any } = if type(store.presets) == "table" then table.clone(store.presets) else {}
	local n_agents, n_presets = 0, 0
	for id, entry in (layer.agents or {}) :: { [string]: any } do
		agents[id] = util.merge(agents[id], entry)
		n_agents += 1
	end
	for id, entry in (layer.presets or {}) :: { [string]: any } do
		presets[id] = util.merge(presets[id], entry)
		n_presets += 1
	end
	out.agents = agents
	out.presets = presets
	if layer.default_agent ~= nil and store.default_agent == nil then
		out.default_agent = layer.default_agent
	end
	cfg.save(out)
	shared.reload()
	cx:toast(
		"success",
		"Imported from Orca",
		string.format("%d agent(s), %d preset(s) · %s", n_agents, n_presets, app.tilde(path))
	)
end

return manage
