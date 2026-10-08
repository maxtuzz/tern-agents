-- A stand-in for Tern's `tern` global, enough to load both entries under
-- plain `luau` and drive their handlers. It records what the plugin registers
-- and does; it is not a model of Tern's behavior.

local stub = {}

-- Installs the global `tern` (declared before the local of the same name).
local function install(t: any)
	tern = t
end

local kv: { [string]: any } = {}
local files: { [string]: string } = {}
local json_store: { [string]: any } = {}
local json_seq = 0

stub.registered = {
	commands = {} :: { any },
	blocks = {} :: { [string]: any },
	events = {} :: { [string]: { any } },
	links = {} :: { any },
	exports = {} :: { [string]: any },
	status = nil :: any,
}
stub.processes = {} :: { any }
stub.timers = {} :: { any }
stub.panes = {} :: { any }
stub.env = { HOME = "/Users/me", SHELL = "/bin/zsh" } :: { [string]: string }

local function node(k: string, p: any?, c: any?): any
	return { k = k, p = p, c = c }
end

local ui = {
	span = function(t, s)
		return { t = t, s = s }
	end,
	link = function(t, href, s)
		return { t = t, href = href, s = s }
	end,
	path = function(p, _cwd)
		return { t = p }
	end,
	text = function(spans)
		return node("text", { spans = spans })
	end,
	col = function(children)
		return node("col", nil, children)
	end,
	lines = function(children)
		return node("lines", nil, children)
	end,
	row = function(children)
		return node("row", nil, children)
	end,
	card = function(head, children)
		return node("card", { head = head }, children)
	end,
	section = function(head, children)
		return node("section", { head = head }, children)
	end,
	rule = function(label)
		return node("rule", { label = label })
	end,
	badge = function(t, tone)
		return node("badge", { text = t, tone = tone })
	end,
	kv = function(items)
		return node("kv", { items = items })
	end,
	list = function(items)
		local c = {}
		for i, it in items do
			c[i] = node("item", { label = it.label, detail = it.detail, tone = it.tone, icon = it.icon })
		end
		return node("list", {}, c)
	end,
	md = function(text)
		return node("md", { text = text })
	end,
	node = node,
	el = function(tag, props, children)
		return node(tag, props, children)
	end,
}

local tern: any = {
	context = "host",
	plugin = { id = "agents", name = "Agents", dir = "/plugin", data = "/data" },
	runtime = { os = "macos", jit = false },
	log = {
		debug = function(...) end,
		info = function(...) end,
		warn = function(...) end,
		error = function(...) end,
	},
	json = {
		-- Encoding hands back an opaque handle, so a test can read the value
		-- a dialog was opened with without a JSON implementation.
		encode = function(v)
			json_seq += 1
			local key = "json#" .. json_seq
			json_store[key] = v
			return key
		end,
		decode = function(text)
			local v = json_store[text]
			if v == nil then
				error("tern.json.decode: not stub JSON")
			end
			return v
		end,
		array = function(t)
			return t or {}
		end,
		null = {},
	},
	now = function()
		return os.clock() * 1000
	end,
	getenv = function(name)
		return stub.env[name]
	end,
	timer = function(ms, fn)
		table.insert(stub.timers, { ms = ms, fn = fn })
		return { cancel = function() end }
	end,
	kv = {
		get = function(k)
			return kv[k]
		end,
		set = function(k, v)
			kv[k] = v
		end,
	},
	fs = {
		read = function(p)
			return files[p] or error("tern.fs.read " .. p .. ": No such file")
		end,
		write = function(p, t)
			files[p] = t
		end,
		exists = function(p)
			return files[p] ~= nil
		end,
		mkdir = function(_p) end,
		list = function(_p)
			return {}
		end,
		remove = function(p)
			files[p] = nil
		end,
	},
	process = {
		run = function(argv, opts, cb)
			table.insert(stub.processes, { argv = argv, opts = opts, cb = cb })
		end,
	},
	ui = ui,
	parse = {
		columns = function(_lines)
			return nil
		end,
	},
	block = {
		define = function(id, def)
			stub.registered.blocks[id] = def
		end,
	},
	pane = {
		write = function(_p, _t) end,
		list = function()
			return stub.panes
		end,
	},
	on = function(name, fn)
		stub.registered.events[name] = stub.registered.events[name] or {}
		table.insert(stub.registered.events[name], fn)
	end,
	command = function(def)
		table.insert(stub.registered.commands, def)
	end,
	bind = function(_c, _a) end,
	override = function(_id, _fn) end,
	route = {
		open = function(_fn) end,
		link = function(fn)
			table.insert(stub.registered.links, fn)
		end,
	},
	chrome = {
		status = function(fn)
			stub.registered.status = fn
		end,
		refresh = function() end,
		tab_title = function(_fn) end,
		window_title = function(_fn) end,
	},
	css = function(_n, _s) end,
	carly = {
		export = function(name, spec, fn)
			stub.registered.exports[name] = { spec = spec, fn = fn }
		end,
		context = function(_fn) end,
		schedule = function(_spec)
			return 1
		end,
		tasks = function()
			return {}
		end,
		cancel = function(_id)
			return true
		end,
	},
}

install(tern)
stub.tern = tern
stub.kv = kv
stub.files = files

-- A block cx that records effects.
function stub.block_cx(): any
	local cx = { pane = 7, cwd = "/", cols = 80, rows = 24, opened = {}, frames = {}, exited = nil, renders = 0 }
	function cx:open(target)
		table.insert(self.opened, target)
	end
	function cx:frame(ops)
		table.insert(self.frames, ops)
	end
	function cx:exit(code)
		self.exited = code
	end
	function cx:render()
		self.renders += 1
	end
	function cx:save() end
	function cx:toast(_l, _t, _s) end
	function cx:copy(_t) end
	return cx
end

-- A window cx with one session and a focused shell pane; records toasts,
-- typed text, agent launches and new panes.
function stub.window_cx(cwd: string?): any
	local cx: any = {
		toasts = {},
		typed = {},
		blocks = {},
		launched = {},
		started = {},
		stopped = {},
		interrupted = {},
		closed = {},
		focused = {},
		opens = {},
		next_pane = 100,
		panes = {},
	}
	cx.panes[10] = { pane = 10, cwd = cwd or "/r", title = "", kind = "terminal", busy = false, at_prompt = true }
	cx.session = {
		focused = function(_self)
			return 10
		end,
		pane = function(_self, id)
			return cx.panes[id]
		end,
		panes = function(_self)
			local out = {}
			for _, info in cx.panes do
				table.insert(out, info)
			end
			return out
		end,
		sessions = function(_self)
			return {}
		end,
		layout = function(_self, _tab)
			return nil
		end,
	}
	local function add_pane(kind: string, dir: string?)
		cx.next_pane += 1
		cx.panes[cx.next_pane] = {
			pane = cx.next_pane,
			cwd = dir or cwd or "/r",
			title = "",
			kind = kind,
			busy = false,
		}
		return cx.next_pane
	end
	cx.agents = {
		start = function(_self, opts)
			if opts.prompt == nil or opts.prompt == "" then
				error("agent command, cwd and prompt must not be blank")
			end
			local pane = add_pane("agent", opts.cwd)
			table.insert(cx.started, { opts = opts, pane = pane })
			return pane
		end,
		list = function(_self)
			return {}
		end,
		stop = function(_self, pane)
			table.insert(cx.stopped, pane)
			cx.panes[pane] = nil
		end,
		interrupt = function(_self, pane)
			table.insert(cx.interrupted, pane)
		end,
		ask = function(_self, _pane, _text)
			error("agent already has a pending prompt")
		end,
	}
	cx.layout = {
		new_tab = function(_self, launch, _reveal)
			local pane = add_pane("terminal", if launch then launch.cwd else nil)
			table.insert(cx.launched, { kind = "tab", launch = launch, pane = pane })
			return pane
		end,
		split = function(_self, target, dir, launch, _reveal)
			local pane = add_pane("terminal", if launch then launch.cwd else nil)
			table.insert(cx.launched, { kind = "split", target = target, dir = dir, launch = launch, pane = pane })
			return pane
		end,
		close = function(_self, pane)
			table.insert(cx.closed, pane)
			cx.panes[pane] = nil
		end,
		focus = function(_self, pane)
			table.insert(cx.focused, pane)
		end,
	}
	function cx:toast(level, text, sub)
		table.insert(self.toasts, { level = level, text = text, sub = sub })
	end
	function cx:run(pane, text)
		table.insert(self.typed, { pane = pane, text = text })
	end
	function cx:open(target, how)
		table.insert(self.opens, { target = target, how = how })
	end
	function cx:action(_name) end
	function cx:new_block(kind, args, how)
		table.insert(self.blocks, { kind = kind, args = args, how = how })
		return 99
	end
	function cx:ask_carly(_text) end
	function cx:copy(_text) end
	return cx
end

-- The launch argument of the last block the window opened, decoded.
function stub.last_block(cx: any): (any, string)
	local block = cx.blocks[#cx.blocks]
	if block == nil then
		error("no block was opened", 2)
	end
	return tern.json.decode(block.args[1]), block.kind
end

-- Answers the oldest pending process with `stdout` and `status`; returns its argv.
function stub.answer(cx: any, status: number, stdout: string?): { string }
	local p = table.remove(stub.processes, 1)
	if p == nil then
		error("no pending process", 2)
	end
	p.cb({ status = status, stdout = stdout or "", stderr = "", timed_out = false }, cx)
	return p.argv
end

function stub.key(name: string, text: string?): any
	return { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }
end

-- Clears the stores between test groups.
function stub.reset()
	for k in kv do
		kv[k] = nil
	end
	for k in files do
		files[k] = nil
	end
	stub.processes = {}
	stub.timers = {}
	stub.panes = {}
end

return stub
