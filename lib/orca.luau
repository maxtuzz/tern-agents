--!strict
-- Reading Orca's agent settings, so a user who already configured their
-- agents there doesn't type it all again. Read-only, optional and tolerant:
-- a missing file, a different Orca version or an unexpected shape yields an
-- empty layer rather than an error.
--
-- Orca 1.4.x keeps them in `~/Library/Application Support/Orca/orca-data.json`
-- under `settings`:
--   defaultTuiAgent      the agent a new terminal starts
--   disabledTuiAgents    agents hidden from its menus
--   agentCmdOverrides    agent id → a whole command line
--   agentDefaultArgs     agent id → its "yolo" arguments
--   agentDefaultEnv      agent id → environment variables
--   terminalQuickCommands  saved launchers; `action = "agent-prompt"` ones
--                          carry an agent and a prompt
--
-- `layer` is pure and returns a table `lib/config` can apply.

local util = require("./util")

local orca = {}

-- Orca's agent ids that we spell differently.
local ALIASES: { [string]: string } = {
	cursor = "cursor-agent",
	["qwen-code"] = "qwen",
	["claude-agent-teams"] = "claude",
}

local function id_of(raw: any): string?
	local id = util.clean(raw)
	if id == nil then
		return nil
	end
	return ALIASES[id] or id
end

local function settings_of(raw: any): any
	if type(raw) ~= "table" then
		return nil
	end
	if type(raw.settings) == "table" then
		return raw.settings
	end
	return raw
end

-- A config layer built from a decoded `orca-data.json` (or just its
-- `settings` table). Agents named only by Orca become profiles whose binary
-- is their id, and are shown only when one is found on PATH.
function orca.layer(raw: any): { [string]: any }
	local settings = settings_of(raw)
	local layer: { [string]: any } = {}
	if settings == nil then
		return layer
	end
	local agents: { [string]: any } = {}
	local presets: { [string]: any } = {}

	local function agent_entry(id: string): { [string]: any }
		local entry = agents[id]
		if entry == nil then
			entry = { id = id, bin = id }
			agents[id] = entry
		end
		return entry
	end

	if type(settings.agentCmdOverrides) == "table" then
		for key, value in settings.agentCmdOverrides do
			local id = id_of(key)
			local line = util.clean(value)
			if id ~= nil and line ~= nil then
				agent_entry(id)
				presets[id .. ":orca"] = { agent = id, name = "orca", command = line }
			end
		end
	end

	if type(settings.agentDefaultArgs) == "table" then
		for key, value in settings.agentDefaultArgs do
			local id = id_of(key)
			local args = util.clean(value)
			if id ~= nil and args ~= nil then
				agent_entry(id)
				presets[id .. ":yolo"] = { agent = id, name = "yolo", args = args }
			end
		end
	end

	if type(settings.agentDefaultEnv) == "table" then
		for key, value in settings.agentDefaultEnv do
			local id = id_of(key)
			local env = util.env_map(value)
			if id ~= nil and next(env) ~= nil then
				local entry = agent_entry(id)
				entry.env = env
			end
		end
	end

	if type(settings.terminalQuickCommands) == "table" then
		for _, value in settings.terminalQuickCommands do
			if type(value) == "table" and util.clean(value.action) == "agent-prompt" then
				local id = id_of(value.agent)
				local prompt = util.clean(value.prompt)
				local name = util.slug(util.clean(value.label) or "")
				if id ~= nil and prompt ~= nil and name ~= "" then
					agent_entry(id)
					presets[id .. ":" .. name] = { agent = id, name = name, prompt = prompt }
				end
			end
		end
	end

	local disabled = settings.disabledTuiAgents
	if type(disabled) == "table" then
		for _, value in disabled do
			local id = id_of(value)
			-- `claude-agent-teams` aliases to claude, which the user plainly
			-- does use; only hide an agent Orca names in its own right.
			if id ~= nil and ALIASES[util.clean(value) :: string] == nil then
				local entry = agent_entry(id)
				entry.hidden = true
			end
		end
	end

	if next(agents) ~= nil then
		layer.agents = agents
	end
	if next(presets) ~= nil then
		layer.presets = presets
	end
	local default_agent = id_of(settings.defaultTuiAgent)
	if default_agent ~= nil then
		layer.default_agent = default_agent
	end
	return layer
end

-- Where Orca keeps its data on this machine.
function orca.path(home: string?): string
	return (home or "~") .. "/Library/Application Support/Orca/orca-data.json"
end

-- Reads and parses Orca's settings. Returns the layer and a problem string;
-- an absent file is not a problem, it is an empty layer.
function orca.read(path: string): ({ [string]: any }, string?)
	if not tern.fs.exists(path) then
		return {}, nil
	end
	local read, text = pcall(tern.fs.read, path, 8 * 1024 * 1024)
	if not read then
		return {}, "Orca's settings can't be read"
	end
	local decoded, value = pcall(tern.json.decode, text)
	if not decoded then
		return {}, "Orca's settings aren't valid JSON"
	end
	return orca.layer(value), nil
end

return orca
