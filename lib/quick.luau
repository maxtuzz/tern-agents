--!strict
-- The one-line launch grammar of "Quick agent…":
--
--   claude yolo fix the build     agent, preset, prompt
--   claude fix the build          agent, its default preset, prompt
--   yolo fix it                   the default agent's "yolo" preset
--   opus: explain this            a trailing colon ends the agent/preset part
--   codex                         just an agent, no prompt
--   claude yolo @~/dev/app look   a directory, anywhere in the line
--
-- Only tokens that name a known agent or one of its presets are eaten, so a
-- prompt beginning with an ordinary word stays whole. `in <dir>` is
-- deliberately not grammar: it would swallow the end of "fix the test in
-- utils". A directory is always `@<path>`.
--
-- Pure: `parse` is given the lookups, so the tests drive it with a fake
-- registry and the dialog previews it against the live one.

local util = require("./util")

local quick = {}

export type Lookup = {
	--- The agent id `token` names, or nil.
	agent: (token: string) -> string?,
	--- The preset id `token` names for `agent`, or nil.
	preset: (agent: string, token: string) -> string?,
	--- The agent a line without one uses, or nil.
	default_agent: () -> string?,
}

export type Parsed = {
	agent: string?,
	preset: string?,
	prompt: string?,
	cwd: string?,
	problem: string?,
}

type Token = { text: string, from: number, to: number }

-- `line` split into words, with each word's byte range.
local function tokens(line: string): { Token }
	local out: { Token } = {}
	local at = 1
	while at <= #line do
		local from, to = string.find(line, "%S+", at)
		if from == nil or to == nil then
			break
		end
		table.insert(out, { text = string.sub(line, from, to), from = from, to = to })
		at = to + 1
	end
	return out
end

-- A token without its grammar-ending colon, and whether it had one.
local function uncolon(text: string): (string, boolean)
	local stem = string.match(text, "^(.-):$")
	if stem ~= nil and stem ~= "" then
		return stem, true
	end
	return text, false
end

-- Parses `line`. Never raises: a problem comes back in `problem`.
function quick.parse(line: string, lookup: Lookup): Parsed
	local text = util.trim(line)
	if text == "" then
		return {}
	end
	local words = tokens(text)

	-- `@<dir>` anywhere, and not part of the prompt.
	local cwd: string? = nil
	local kept: { Token } = {}
	for _, word in words do
		local dir = string.match(word.text, "^@(.+)$")
		if dir ~= nil and cwd == nil then
			cwd = dir
		else
			table.insert(kept, word)
		end
	end
	if cwd ~= nil and util.clean(cwd) == nil then
		return { problem = "Type a directory after @" }
	end

	local index = 1
	local agent: string? = nil
	local preset: string? = nil

	local first = kept[index]
	if first ~= nil then
		local stem, colon = uncolon(first.text)
		local found = lookup.agent(stem)
		if found ~= nil then
			agent = found
			index += 1
		else
			-- Not an agent: it may name a preset of the default agent.
			local default = lookup.default_agent()
			local as_preset = if default ~= nil then lookup.preset(default, stem) else nil
			if as_preset ~= nil then
				agent = default
				preset = as_preset
				index += 1
			elseif colon then
				return {
					agent = nil,
					preset = nil,
					prompt = nil,
					cwd = cwd,
					problem = string.format("No agent or preset %q", stem),
				}
			end
		end
	end

	if agent ~= nil and preset == nil then
		local second = kept[index]
		if second ~= nil then
			local stem, colon = uncolon(second.text)
			local found = lookup.preset(agent :: string, stem)
			if found ~= nil then
				preset = found
				index += 1
			elseif colon then
				return {
					agent = agent,
					preset = nil,
					prompt = nil,
					cwd = cwd,
					problem = string.format("No preset %q for that agent", stem),
				}
			end
		end
	end

	local rest = kept[index]
	local prompt: string? = nil
	if rest ~= nil then
		local tail = util.trim(string.sub(text, rest.from))
		-- A `@dir` that sat inside the prompt is taken out of it too.
		if cwd ~= nil then
			tail = util.trim((string.gsub(tail, "%s*@" .. string.gsub(cwd, "(%W)", "%%%1") .. "%f[%s\0]", "")))
		end
		prompt = util.clean(tail)
	end

	return { agent = agent, preset = preset, prompt = prompt, cwd = cwd }
end

return quick
