--!strict
-- The rows of the Agents block: the plugin's launch records joined with what
-- each pane currently says. Pure, so the tests check the join and the
-- counting without Tern.

local runs = require("./runs")
local status = require("./status")

local model = {}

export type Row = {
	pane: number,
	label: string,
	agent: string,
	preset: string,
	cwd: string,
	kind: string,
	status: status.Status,
	--- Seconds since the launch.
	age: number,
	--- The pane's title, when it has one worth showing.
	title: string?,
}

-- One row per record, newest first. `facts` is pane id → what the pane says
-- (a missing entry means the pane is gone).
function model.rows(records: { runs.Record }, facts: { [number]: status.PaneFacts }, now: number): { Row }
	local out: { Row } = {}
	for _, record in records do
		local fact = facts[record.pane]
		local merged: status.PaneFacts? = if fact == nil
			then nil
			else {
				title = fact.title,
				busy = fact.busy,
				-- A record's stored exit status outlives a pane listing that
				-- no longer reports one.
				exited = fact.exited or record.exited,
			}
		table.insert(out, {
			pane = record.pane,
			label = record.label,
			agent = record.agent,
			preset = record.preset,
			cwd = record.cwd,
			kind = record.kind or "block",
			status = status.of(merged, record.title_status),
			age = math.max(0, now - record.started_at),
			title = if fact then fact.title else nil,
		})
	end
	return out
end

export type Counts = { total: number, working: number, idle: number, gone: number }

function model.counts(rows: { Row }): Counts
	local counts: Counts = { total = #rows, working = 0, idle = 0, gone = 0 }
	for _, row in rows do
		local state = row.status.state
		if state == "working" then
			counts.working += 1
		elseif state == "idle" then
			counts.idle += 1
		elseif state == "exited" or state == "closed" then
			counts.gone += 1
		end
	end
	return counts
end

-- Our status as the native `agent` element's own status.
local AGENT_STATUS: { [string]: string } = {
	working = "running",
	idle = "idle",
	running = "pending",
	exited = "done",
	closed = "aborted",
}

function model.element_status(row: Row): string
	if row.status.state == "exited" and (row.status.code or 0) ~= 0 then
		return "failed"
	end
	return AGENT_STATUS[row.status.state] or "pending"
end

return model
