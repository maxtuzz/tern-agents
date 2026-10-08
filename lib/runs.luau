--!strict
-- The plugin's own launches, in `tern.kv` under "runs", keyed by pane id.
--
-- Tern's `cx.agents:list()` knows an agent block's command line and state but
-- not which profile or preset it came from, and `PaneInfo.program` reads the
-- login shell's name when a launch is wrapped in one. So the plugin keeps its
-- own record: which agent, which preset, where, when, and how it was placed.
-- The record is what the Agents block lists, what "Restart agent" repeats and
-- what Carly's `running()` returns, and it survives a plugin reload.
--
-- Both halves read it; the window half creates and prunes records and the
-- host half fills in exit statuses from `pane_exited`.

local runs = {}

export type Record = {
	pane: number,
	agent: string,
	preset: string,
	--- "Claude Code · yolo", for lists that shouldn't resolve the config.
	label: string,
	cwd: string,
	--- The command line Tern was given.
	command: string,
	--- The command line before login-shell wrapping.
	inner: string?,
	--- Unix seconds.
	started_at: number,
	--- "split", "tab", "replace_if_alone".
	how: string?,
	--- "block" (a real agent block) or "argv" (a terminal pane).
	kind: string?,
	--- The prompt the launch delivered, when there was one.
	prompt: string?,
	--- Exit status, filled in by the host half when the program ends.
	exited: number?,
	--- The pane's title heuristic, from the agent profile.
	title_status: string?,
}

local KEY = "runs"
-- A record is never pruned before this, so a launch can't be swept away
-- between `start` returning and the pane appearing in a listing.
local GRACE_SECONDS = 10

-- Every record by pane id. A store that can't be read counts as empty.
function runs.all(): { [number]: Record }
	local ok, value = pcall(tern.kv.get, KEY)
	local out: { [number]: Record } = {}
	if not ok or type(value) ~= "table" then
		return out
	end
	for key, record in value do
		local pane = if type(key) == "number" then key else tonumber(key)
		if pane ~= nil and type(record) == "table" and type(record.agent) == "string" then
			out[pane] = record
		end
	end
	return out
end

local function write(all: { [number]: Record })
	local store: { [string]: Record } = {}
	for pane, record in all do
		store[tostring(pane)] = record
	end
	tern.kv.set(KEY, store)
end

-- Records newest first.
function runs.list(): { Record }
	local out: { Record } = {}
	for _, record in runs.all() do
		table.insert(out, record)
	end
	table.sort(out, function(a: Record, b: Record): boolean
		if a.started_at ~= b.started_at then
			return a.started_at > b.started_at
		end
		return a.pane > b.pane
	end)
	return out
end

function runs.get(pane: number): Record?
	return runs.all()[pane]
end

function runs.put(record: Record)
	local all = runs.all()
	all[record.pane] = record
	write(all)
end

-- Merges `fields` into the record for `pane`, when there is one.
function runs.patch(pane: number, fields: { [string]: any })
	local all = runs.all()
	local record = all[pane]
	if record == nil then
		return
	end
	local merged: { [string]: any } = table.clone(record :: any)
	for k, v in fields do
		merged[k] = v
	end
	all[pane] = merged :: any
	write(all)
end

function runs.drop(pane: number)
	local all = runs.all()
	if all[pane] ~= nil then
		all[pane] = nil
		write(all)
	end
end

-- Which records `alive` (pane id → true) says are gone, ignoring ones young
-- enough that the pane may not be listed yet. Pure, so the tests cover it.
function runs.stale(all: { [number]: Record }, alive: { [number]: boolean }, now: number): { number }
	local out: { number } = {}
	for pane, record in all do
		if not alive[pane] and now - record.started_at > GRACE_SECONDS then
			table.insert(out, pane)
		end
	end
	table.sort(out)
	return out
end

-- Drops the records of panes that are gone. Returns how many went.
function runs.prune(alive: { [number]: boolean }): number
	local all = runs.all()
	local gone = runs.stale(all, alive, os.time())
	if #gone == 0 then
		return 0
	end
	local kept: { [number]: Record } = {}
	for pane, record in all do
		kept[pane] = record
	end
	for _, pane in gone do
		kept[pane] = nil
	end
	write(kept)
	return #gone
end

return runs
