--!strict
-- The one-line grammars of the editing commands, kept apart from their
-- dialogs so they are pure and tested:
--
--   Add preset…  `<agent> <name> [args…]`   claude yolo --dangerously-skip-permissions
--   Add agent…   `<id> [binary] [args…]`    mycli /opt/bin/mycli --quiet
--
-- Neither grammar covers every field; `agents.json` does, and the dialogs
-- say so.

local util = require("./util")
local config = require("./config")

local forms = {}

export type PresetLine = {
	agent: string?,
	name: string?,
	args: { string },
	problem: string?,
}

export type AgentLine = {
	id: string?,
	bin: string?,
	args: { string },
	problem: string?,
}

local function words(line: string): { string }
	local out: { string } = {}
	for word in string.gmatch(util.trim(line), "%S+") do
		table.insert(out, word)
	end
	return out
end

-- `<agent> <name> [args…]`. `known` decides whether the first word names an
-- agent, so a typo is reported rather than stored.
function forms.parse_preset(line: string, known: (string) -> boolean): PresetLine
	local parts = words(line)
	if #parts == 0 then
		return { args = {} }
	end
	local agent = parts[1]
	if not known(agent) then
		return { args = {}, problem = string.format("No agent %q; \"Add agent…\" first", agent) }
	end
	if #parts == 1 then
		return { agent = agent, args = {}, problem = "Type a name for the preset" }
	end
	local name = parts[2]
	local problem = config.id_problem(name)
	if problem ~= nil then
		return { agent = agent, args = {}, problem = problem }
	end
	local rest = string.match(util.trim(line), "^%S+%s+%S+%s*(.*)$") or ""
	return { agent = agent, name = name, args = util.split_args(rest) }
end

-- `<id> [binary] [args…]`. The binary defaults to the id.
function forms.parse_agent(line: string): AgentLine
	local parts = words(line)
	if #parts == 0 then
		return { args = {} }
	end
	local id = parts[1]
	local problem = config.id_problem(id)
	if problem ~= nil then
		return { args = {}, problem = problem }
	end
	if #parts == 1 then
		return { id = id, bin = id, args = {} }
	end
	local bin = parts[2]
	local rest = string.match(util.trim(line), "^%S+%s+%S+%s*(.*)$") or ""
	return { id = id, bin = bin, args = util.split_args(rest) }
end

return forms
