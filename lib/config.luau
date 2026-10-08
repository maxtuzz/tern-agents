--!strict
-- Agent profiles, run presets and defaults: the built-in catalog with the
-- user's own entries laid over it.
--
-- Three layers, each winning over the one before:
--   1. `lib/catalog` — what the plugin ships.
--   2. `tern.kv` key "config" — what the palette commands write.
--   3. `agents.json` in the plugin data dir — hand-edited, so it wins.
-- A malformed `agents.json` is reported and ignored, so a typo can never
-- take the plugin's commands away (the same rule as tern-worktrees'
-- `repos.json`).
--
-- Everything here except `config.load` is pure, so the tests exercise the
-- real merge and resolution rules with plain `luau`.

local util = require("./util")
local catalog = require("./catalog")

local config = {}

export type Agent = {
	id: string,
	label: string,
	bin: string,
	args: { string },
	env: { [string]: string },
	icon: string,
	prompt_arg: string,
	title_status: string,
	--- A whole command line replacing `bin` and `args` (Orca's agentCmdOverrides).
	command: string?,
	--- Run through the user's login shell (default true; see lib/command).
	shell: boolean?,
	--- "block" (prompt typed into a real agent block) or "argv".
	prompt_delivery: string?,
	--- Hidden from the pickers even when it is on PATH.
	hidden: boolean?,
	--- Its flags were checked against the CLI's own `--help`.
	verified: boolean,
	note: string?,
	--- Where it came from: "builtin", "kv" or "agents.json".
	source: string,
}

export type Preset = {
	id: string,
	name: string,
	agent: string,
	args: { string },
	--- Drop the agent's default args instead of appending to them.
	replace_args: boolean?,
	env: { [string]: string }?,
	--- A whole command line, replacing the agent's `bin`, `args` and `command`.
	command: string?,
	--- An initial prompt the preset always sends.
	prompt: string?,
	--- Placement: "split", "tab" or "replace_if_alone".
	how: string?,
	--- A fixed directory to run in; otherwise the launch decides.
	cwd: string?,
	--- Run through the user's login shell; overrides the agent's own choice.
	shell: boolean?,
	prompt_delivery: string?,
	builtin: boolean?,
	source: string,
}

export type Config = {
	agents: { [string]: Agent },
	presets: { [string]: Preset },
	default_agent: string?,
	--- Preset id per agent id.
	default_presets: { [string]: string },
	--- The preset a bare launch uses when no agent is named.
	default_preset: string?,
	shell: boolean,
	prompt_delivery: string,
	--- Readable complaints about the stored or declared config.
	problems: { string },
}

config.FILE = "agents.json"
config.KEY = "config"

local HOWS: { [string]: boolean } = { split = true, tab = true, replace_if_alone = true }
local DELIVERIES: { [string]: boolean } = { block = true, argv = true }

-- Quick entry spends these words on grammar, so they can't be agent ids.
local RESERVED: { [string]: boolean } = { ["in"] = true }

function config.id_problem(id: string): string?
	if id == "" then
		return "Type an id"
	end
	if #id > 40 then
		return "Ids are at most 40 characters"
	end
	if not string.match(id, "^[%a%d][%w%._%-]*$") then
		return "An id starts with a letter or digit and holds only letters, digits, . _ -"
	end
	if RESERVED[string.lower(id)] then
		return string.format("%q is a quick-entry keyword; pick another id", id)
	end
	return nil
end

local function one_of(value: any, allowed: { [string]: boolean }): string?
	local s = util.clean(value)
	if s ~= nil and allowed[s] then
		return s
	end
	return nil
end

local function bool_or(value: any, fallback: boolean?): boolean?
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

-- One agent profile from a raw entry laid over `base` (a built-in or an
-- earlier layer). Returns nil when the entry can't name an agent at all.
function config.normalize_agent(id: string, raw: any, base: Agent?, source: string): Agent?
	if type(raw) ~= "table" then
		return nil
	end
	local wanted = util.clean(raw.id) or id
	if wanted == nil or config.id_problem(wanted) ~= nil then
		return nil
	end
	local args = if raw.args ~= nil then util.string_list(raw.args) else (if base then base.args else {})
	return {
		id = wanted,
		label = util.clean(raw.label) or (if base then base.label else wanted),
		bin = util.clean(raw.bin) or util.clean(raw.command_name) or (if base then base.bin else wanted),
		args = args,
		env = if raw.env ~= nil then util.env_map(raw.env) else (if base then base.env else {}),
		icon = util.clean(raw.icon) or (if base then base.icon else "sparkle"),
		prompt_arg = util.clean(raw.prompt_arg) or (if base then base.prompt_arg else "none"),
		title_status = util.clean(raw.title_status) or (if base then base.title_status else "none"),
		command = util.clean(raw.command) or (if base then base.command else nil),
		shell = bool_or(raw.shell, if base then base.shell else nil),
		prompt_delivery = one_of(raw.prompt_delivery, DELIVERIES)
			or (if base then base.prompt_delivery else nil),
		hidden = bool_or(raw.hidden, if base then base.hidden else nil),
		verified = if base then base.verified else false,
		note = util.clean(raw.note) or (if base then base.note else nil),
		source = source,
	}
end

-- One preset from a raw entry laid over `base`. `fallback_agent` is used when
-- the entry names no agent (a preset keyed `claude:yolo` implies `claude`).
function config.normalize_preset(id: string, raw: any, base: Preset?, source: string): Preset?
	if type(raw) ~= "table" then
		return nil
	end
	local keyed_agent, keyed_name = string.match(id, "^([^:]+):(.+)$")
	local agent = util.clean(raw.agent) or (if base then base.agent else keyed_agent)
	if agent == nil or config.id_problem(agent) ~= nil then
		return nil
	end
	local name = util.clean(raw.name) or (if base then base.name else nil) or keyed_name or id
	local wanted = util.clean(raw.id) or (if keyed_agent then id else agent .. ":" .. util.slug(name))
	if wanted == "" then
		return nil
	end
	return {
		id = wanted,
		name = name,
		agent = agent,
		args = if raw.args ~= nil then util.string_list(raw.args) else (if base then base.args else {}),
		replace_args = bool_or(raw.replace_args, if base then base.replace_args else nil),
		env = if raw.env ~= nil then util.env_map(raw.env) else (if base then base.env else nil),
		command = util.clean(raw.command) or (if base then base.command else nil),
		prompt = util.clean(raw.prompt) or (if base then base.prompt else nil),
		how = one_of(raw.how, HOWS) or (if base then base.how else nil),
		cwd = util.clean(raw.cwd) or (if base then base.cwd else nil),
		shell = bool_or(raw.shell, if base then base.shell else nil),
		prompt_delivery = one_of(raw.prompt_delivery, DELIVERIES) or (if base then base.prompt_delivery else nil),
		builtin = if base then base.builtin else nil,
		source = source,
	}
end

-- Entries of `raw.agents` / `raw.presets`, accepting both an object keyed by
-- id and an array of entries carrying their own `id`.
local function entries(raw: any): { { key: string, value: any } }
	local out: { { key: string, value: any } } = {}
	if type(raw) ~= "table" then
		return out
	end
	for k, v in raw do
		if type(k) == "string" then
			table.insert(out, { key = k, value = v })
		elseif type(v) == "table" then
			local id = util.clean(v.id)
			if id ~= nil then
				table.insert(out, { key = id, value = v })
			end
		end
	end
	table.sort(out, function(a, b): boolean
		return a.key < b.key
	end)
	return out
end

local function fresh(): Config
	return {
		agents = catalog.agents() :: any,
		presets = catalog.presets() :: any,
		default_agent = nil,
		default_presets = {},
		default_preset = nil,
		shell = true,
		prompt_delivery = "block",
		problems = {},
	}
end

-- The built-in config, with no user layers.
function config.defaults(): Config
	local cfg = fresh()
	for _, agent in cfg.agents do
		(agent :: any).source = "builtin"
	end
	for _, preset in cfg.presets do
		(preset :: any).source = "builtin"
	end
	return cfg
end

-- `layer` (a decoded store or file) laid over `cfg`. Returns a new config;
-- neither input changes. Unusable entries are listed in `problems` with
-- `source` named, and otherwise ignored.
function config.apply(cfg: Config, layer: any, source: string): Config
	local out: Config = {
		agents = util.merge(cfg.agents :: any, nil) :: any,
		presets = util.merge(cfg.presets :: any, nil) :: any,
		default_agent = cfg.default_agent,
		default_presets = util.merge(cfg.default_presets :: any, nil) :: any,
		default_preset = cfg.default_preset,
		shell = cfg.shell,
		prompt_delivery = cfg.prompt_delivery,
		problems = table.clone(cfg.problems),
	}
	if layer == nil then
		return out
	end
	if type(layer) ~= "table" then
		table.insert(out.problems, source .. " must hold a JSON object")
		return out
	end
	for _, entry in entries(layer.agents) do
		local agent = config.normalize_agent(entry.key, entry.value, out.agents[entry.key], source)
		if agent == nil then
			table.insert(out.problems, string.format("%s: agent %q is not usable", source, entry.key))
		else
			out.agents[agent.id] = agent
		end
	end
	-- Removals come first, so a layer that both hides a preset and defines one
	-- of that name (the palette's "Remove preset…" then "Add preset…") ends up
	-- with the preset, and a later layer can always bring one back.
	for _, id in util.string_list(layer.remove_presets) do
		out.presets[id] = nil
		out.default_preset = if out.default_preset == id then nil else out.default_preset
	end
	for _, entry in entries(layer.presets) do
		local preset = config.normalize_preset(entry.key, entry.value, out.presets[entry.key], source)
		if preset == nil then
			table.insert(out.problems, string.format("%s: preset %q is not usable", source, entry.key))
		else
			out.presets[preset.id] = preset
		end
	end
	local default_agent = util.clean(layer.default_agent)
	if default_agent ~= nil then
		out.default_agent = default_agent
	end
	if type(layer.default_presets) == "table" then
		for agent_id, preset_id in layer.default_presets do
			local a = util.clean(agent_id)
			local p = util.clean(preset_id)
			if a ~= nil and p ~= nil then
				out.default_presets[a] = p
			end
		end
	end
	local default_preset = util.clean(layer.default_preset)
	if default_preset ~= nil then
		out.default_preset = default_preset
	end
	if type(layer.shell) == "boolean" then
		out.shell = layer.shell
	end
	local delivery = one_of(layer.prompt_delivery, DELIVERIES)
	if delivery ~= nil then
		out.prompt_delivery = delivery
	end
	return out
end

-- The whole config from the stored and declared layers (both already
-- decoded). `declared` is the hand-edited file, so it goes on last.
function config.build(stored: any, declared: any): Config
	local cfg = config.apply(config.defaults(), stored, "kv")
	return config.apply(cfg, declared, config.FILE)
end

-- The agent `token` names: its id, its label, or its binary, ignoring case.
function config.find_agent(cfg: Config, token: string?): Agent?
	local want = string.lower(util.trim(token or ""))
	if want == "" then
		return nil
	end
	local by_id = cfg.agents[want]
	if by_id ~= nil then
		return by_id
	end
	for _, agent in cfg.agents do
		if string.lower(agent.id) == want or string.lower(agent.label) == want or string.lower(agent.bin) == want then
			return agent
		end
	end
	return nil
end

-- The presets of one agent: its plain preset first, then by name.
function config.presets_of(cfg: Config, agent_id: string): { Preset }
	local out: { Preset } = {}
	for _, preset in cfg.presets do
		if preset.agent == agent_id then
			table.insert(out, preset)
		end
	end
	table.sort(out, function(a: Preset, b: Preset): boolean
		local a_plain = a.name == agent_id
		local b_plain = b.name == agent_id
		if a_plain ~= b_plain then
			return a_plain
		end
		return a.name < b.name
	end)
	return out
end

-- The preset `token` names for `agent_id`: its id, or its name.
function config.find_preset(cfg: Config, agent_id: string, token: string?): Preset?
	local want = string.lower(util.trim(token or ""))
	if want == "" then
		return nil
	end
	local direct = cfg.presets[want] or cfg.presets[agent_id .. ":" .. want]
	if direct ~= nil and direct.agent == agent_id then
		return direct
	end
	for _, preset in config.presets_of(cfg, agent_id) do
		if string.lower(preset.name) == want then
			return preset
		end
	end
	return nil
end

-- The preset an agent launches with when none was named: its configured
-- default, else the global default when it belongs to this agent, else the
-- agent's plain preset, else its first preset.
function config.default_preset_of(cfg: Config, agent_id: string): Preset?
	local wanted = cfg.default_presets[agent_id]
	local chosen = if wanted then config.find_preset(cfg, agent_id, wanted) else nil
	if chosen ~= nil then
		return chosen
	end
	local global = if cfg.default_preset then cfg.presets[cfg.default_preset] else nil
	if global ~= nil and global.agent == agent_id then
		return global
	end
	local list = config.presets_of(cfg, agent_id)
	return list[1]
end

-- The agent and preset a launch should use. `agent_token` and `preset_token`
-- are what the user typed (either may be nil). `available` is the ids worth
-- offering (detected agents); nil accepts every agent. Raises a readable
-- message when nothing fits.
function config.resolve(
	cfg: Config,
	agent_token: string?,
	preset_token: string?,
	available: { [string]: boolean }?
): (Agent, Preset)
	local agent: Agent? = config.find_agent(cfg, agent_token)
	if agent == nil and util.clean(agent_token) ~= nil then
		error(string.format("No agent %q; add one with \"Add agent…\"", util.trim(agent_token :: string)), 0)
	end
	if agent == nil then
		-- No agent named: the global default preset decides, else the default
		-- agent, else the only detected agent.
		local global = if cfg.default_preset then cfg.presets[cfg.default_preset] else nil
		if preset_token == nil and global ~= nil then
			agent = cfg.agents[global.agent]
		end
		if agent == nil and cfg.default_agent ~= nil then
			agent = config.find_agent(cfg, cfg.default_agent)
		end
		if agent == nil and available ~= nil then
			local only: Agent? = nil
			local count = 0
			for id in available do
				local candidate = cfg.agents[id]
				if candidate ~= nil and not candidate.hidden then
					count += 1
					only = candidate
				end
			end
			agent = if count == 1 then only else nil
		end
	end
	if agent == nil then
		error("No default agent; run \"Set default preset…\" or name one", 0)
	end
	local found: Agent = agent
	local preset: Preset? = if preset_token ~= nil
		then config.find_preset(cfg, found.id, preset_token)
		else config.default_preset_of(cfg, found.id)
	if preset == nil and preset_token ~= nil then
		error(
			string.format("No preset %q for %s", util.trim(preset_token :: string), found.label),
			0
		)
	end
	if preset == nil then
		error(string.format("No presets for %s; add one with \"Add preset…\"", found.label), 0)
	end
	return found, preset
end

-- Every agent worth showing, built-ins in catalog order then the user's own,
-- hidden ones left out. `detected` (id → true) filters them: an agent the
-- hand-edited file names is always shown, because writing it there is a
-- statement that it exists, while built-ins and imported entries wait until
-- their binary turns up on PATH.
function config.agent_list(cfg: Config, detected: { [string]: boolean }?): { Agent }
	local order = catalog.order()
	local rank: { [string]: number } = {}
	for i, id in order do
		rank[id] = i
	end
	local out: { Agent } = {}
	for _, agent in cfg.agents do
		local shown = not agent.hidden
			and (detected == nil or detected[agent.id] == true or agent.source == config.FILE)
		if shown then
			table.insert(out, agent)
		end
	end
	table.sort(out, function(a: Agent, b: Agent): boolean
		local ra = rank[a.id] or (1000 + #out)
		local rb = rank[b.id] or (1000 + #out)
		if ra ~= rb then
			return ra < rb
		end
		return a.id < b.id
	end)
	return out
end

-- Reads the hand-edited file, when there is one. Returns the decoded value
-- and a problem string; both nil when the file is absent.
function config.read_file(path: string): (any, string?)
	if not tern.fs.exists(path) then
		return nil, nil
	end
	local read, text = pcall(tern.fs.read, path, 1024 * 1024)
	if not read then
		return nil, config.FILE .. " can't be read"
	end
	local decoded, value = pcall(tern.json.decode, text)
	if not decoded then
		return nil, config.FILE .. " isn't valid JSON (" .. tostring(value) .. ")"
	end
	return value, nil
end

-- The absolute path of the hand-edited file.
function config.path(): string
	return tern.plugin.data .. "/" .. config.FILE
end

-- The live config: built-ins, then `tern.kv`, then `agents.json`.
function config.load(): Config
	local ok, stored = pcall(tern.kv.get, config.KEY)
	local declared, problem = config.read_file(config.path())
	local cfg = config.build(if ok then stored else nil, declared)
	if not ok then
		table.insert(cfg.problems, "the plugin's kv store can't be read")
	end
	if problem ~= nil then
		table.insert(cfg.problems, problem)
	end
	return cfg
end

-- The stored layer (what the palette commands own), as a plain table.
function config.stored(): { [string]: any }
	local ok, value = pcall(tern.kv.get, config.KEY)
	if ok and type(value) == "table" then
		return value
	end
	return {}
end

-- Writes the stored layer back.
function config.save(store: { [string]: any })
	tern.kv.set(config.KEY, store)
end

-- Merges `fields` into the stored layer's `section` ("agents" or "presets") at
-- `id`; a nil `fields` removes the entry. Returns the new store.
--
-- A merge, not a replacement: "Edit preset…" sends only `args`, and it must
-- not throw away the `command` an Orca import stored, or a preset's `prompt`,
-- `env`, `cwd` and placement. Fields the palette can't reach are changed in
-- `agents.json`.
function config.patch(section: string, id: string, fields: { [string]: any }?): { [string]: any }
	local store = config.stored()
	local sub: { [string]: any } = if type(store[section]) == "table" then table.clone(store[section]) else {}
	local before = sub[id]
	sub[id] = if fields == nil
		then nil
		else util.merge(if type(before) == "table" then before else nil, fields)
	local out = table.clone(store)
	out[section] = sub
	config.save(out)
	return out
end

return config
