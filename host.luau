--!strict
-- agents, host half: the blocks the window half opens (the Agents list, the
-- picker and the one-line dialog), and the exit statuses the window can't
-- see for itself.
--
-- `pane_exited` is a host event: it fires where the programs actually run, so
-- this is the half that can tell "the agent finished" from "the pane is gone".
-- It writes the status into the plugin's own launch record, which both halves
-- and the Agents block read.

local runs = require("./lib/runs")

tern.block.define("list", require("./lib/blocks/list"))
tern.block.define("pick", require("./lib/blocks/pick"))
tern.block.define("line", require("./lib/blocks/line"))

tern.on("pane_exited", function(ev: PaneExitedEvent, _cx: EffectCx)
	local record = runs.get(ev.pane)
	if record ~= nil and record.exited == nil then
		pcall(runs.patch, ev.pane, { exited = ev.status })
	end
end)

