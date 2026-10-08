--!strict
-- agents, host half: the blocks the window half opens (the Agents list, the
-- picker and the one-line dialog), the exit statuses the window can't see for
-- itself, and the sweep that drops records of panes that are gone.
--
-- `pane_exited` is a host event: it fires where the programs actually run, so
-- this is the half that can tell "the agent finished" from "the pane is
-- gone". It is also the half that may prune: `tern.pane.list()` is every pane
-- on this host, while a window sees only its own, and the launch records are
-- shared by every window.

local runs = require("./lib/runs")

tern.block.define("list", require("./lib/blocks/list"))
tern.block.define("pick", require("./lib/blocks/pick"))
tern.block.define("line", require("./lib/blocks/line"))

tern.on("pane_exited", function(ev: PaneExitedEvent, _cx: EffectCx)
	local record = runs.get(ev.pane)
	if record ~= nil and record.exited == nil then
		pcall(runs.patch, ev.pane, { exited = ev.status, exited_at = os.time() })
	end
	-- One agent ending is also the moment to sweep others: a record lives
	-- while its pane does, and for two minutes after its exit, so the Agents
	-- block can still show how it ended.
	pcall(runs.sweep)
end)
