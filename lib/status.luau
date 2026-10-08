--!strict
-- What a launched agent is doing, as far as Tern's APIs can say.
--
-- Tern reads working/idle from a TSP surface and OSC 9;4 progress, which only
-- omp (and Hermes, speaking omp's vocabulary) sends: for every other agent
-- `AgentBlock.state` stays `"working"` for ever and `cx.agents:wait` times
-- out. What is left is honest but thin:
--
--   * the pane's exit status (`PaneInfo.exited`, `pane_closed`),
--   * the pane title, which several TUIs use for their spinner,
--   * `PaneInfo.busy`, when the program reports it.
--
-- So a status is one of: `exited` (with its code), `working`, `idle`,
-- `running` (alive, nothing more known) or `closed`. Pure, and tested.

local status = {}

export type State = "working" | "idle" | "running" | "exited" | "closed"

export type Status = {
	state: State,
	--- A short label for a badge ("working", "exit 1").
	label: string,
	--- A Tern list/badge tone.
	tone: string,
	--- Exit status, when the program ended.
	code: number?,
}

-- Braille and clock spinners, as the common TUI spinner libraries cycle them.
local SPINNERS: { string } = {
	"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
	"⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷",
	"◐", "◑", "◒", "◓", "◴", "◵", "◶", "◷",
	"⬒", "⬔", "⬓", "⬕", "◰", "◳", "◲", "◱",
	"▰", "▱", "◢", "◣", "◤", "◥",
}

-- Claude Code's idle marker, and the asterisk shapes it animates through.
local CLAUDE_IDLE = "✳"
-- Only the asterisk shapes: a middle dot is ordinary punctuation in a title,
-- not a spinner frame, and reading it as progress would be a claim the API
-- can't support.
local CLAUDE_BUSY: { string } = { "✶", "✻", "✽" }

local function holds(text: string, needles: { string }): boolean
	for _, needle in needles do
		if string.find(text, needle, 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- What `title` says about progress for the `kind` heuristic, or nil when it
-- says nothing. `kind` comes from the agent profile's `title_status`.
function status.from_title(title: string?, kind: string?): State?
	local text = title or ""
	if text == "" then
		return nil
	end
	if kind == "claude" then
		if string.find(text, CLAUDE_IDLE, 1, true) ~= nil then
			return "idle"
		end
		if holds(text, SPINNERS) or holds(text, CLAUDE_BUSY) then
			return "working"
		end
		return nil
	end
	if kind == "spinner" then
		if holds(text, SPINNERS) then
			return "working"
		end
		return nil
	end
	return nil
end

export type PaneFacts = {
	title: string?,
	busy: boolean?,
	exited: number?,
}

-- The status of a launch. `facts` is what the pane says (nil when the pane is
-- gone); `kind` is the agent's `title_status` heuristic.
function status.of(facts: PaneFacts?, kind: string?): Status
	if facts == nil then
		return { state = "closed", label = "closed", tone = "muted" }
	end
	local code = facts.exited
	if code ~= nil then
		local ok = code == 0
		return {
			state = "exited",
			label = if ok then "exited" else "exit " .. tostring(code),
			tone = if ok then "muted" else "error",
			code = code,
		}
	end
	local from_title = status.from_title(facts.title, kind)
	if from_title == "working" then
		return { state = "working", label = "working", tone = "info" }
	end
	if from_title == "idle" then
		return { state = "idle", label = "idle", tone = "success" }
	end
	if facts.busy == true then
		return { state = "working", label = "working", tone = "info" }
	end
	return { state = "running", label = "running", tone = "muted" }
end

-- Whether a state means the program is still there.
function status.alive(state: State): boolean
	return state == "working" or state == "idle" or state == "running"
end

return status
