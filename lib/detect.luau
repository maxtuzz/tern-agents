--!strict
-- Which agent CLIs this machine actually has.
--
-- The plugin's own process does not see the user's interactive PATH (nvm,
-- `~/.local/bin`, `~/.opencode/bin` are all set in rc files), so detection
-- asks the user's login shell: one `command -v` per candidate in one
-- `-lic` run, about 200 ms, cached in `tern.kv` with the shell it used.
-- Nothing is probed again until the cache ages out or "Refresh detected
-- agents" asks for it.

local util = require("./util")

local detect = {}

export type Cache = {
	--- Agent id → the absolute path its binary resolved to.
	found: { [string]: string },
	--- Unix seconds the probe ran at.
	at: number,
	--- The shell it asked.
	shell: string,
}

local KEY = "detected"
local TTL_SECONDS = 15 * 60
local PROBE_TIMEOUT_MS = 8000

-- The user's shell, as the launcher and the probe both use it.
function detect.shell(): string
	local shell = util.clean(tern.getenv("SHELL"))
	if shell ~= nil and string.sub(shell, 1, 1) == "/" then
		return shell
	end
	return "/bin/zsh"
end

-- The cached probe, or nil when there is none.
function detect.cached(): Cache?
	local ok, value = pcall(tern.kv.get, KEY)
	if not ok or type(value) ~= "table" or type(value.found) ~= "table" then
		return nil
	end
	return {
		found = value.found,
		at = if type(value.at) == "number" then value.at else 0,
		shell = if type(value.shell) == "string" then value.shell else "",
	}
end

-- Agent id → true for everything the last probe found.
function detect.map(cache: Cache?): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for id in (if cache then cache.found else {}) do
		out[id] = true
	end
	return out
end

-- Whether a fresh probe is worth running.
function detect.stale(cache: Cache?): boolean
	if cache == nil then
		return true
	end
	if cache.shell ~= detect.shell() then
		return true
	end
	return os.time() - cache.at > TTL_SECONDS
end

-- The shell script that prints `<id>\t<path>` for every candidate it finds.
-- It uses only `command -v`, `&&`, `printf` and a substitution, so it runs
-- the same under zsh, bash and fish; a variable assignment would not.
function detect.script(candidates: { { id: string, bin: string } }): string
	local lines: { string } = {}
	for _, candidate in candidates do
		local bin = util.shell_quote(candidate.bin)
		table.insert(
			lines,
			string.format(
				"command -v -- %s >/dev/null 2>&1 && printf '%%s\\t%%s\\n' %s \"$(command -v -- %s)\"",
				bin,
				util.shell_quote(candidate.id),
				bin
			)
		)
	end
	-- A trailing `true`: a candidate that isn't there must not make the whole
	-- script's status non-zero, nor end it under a shell started with `-e`.
	return table.concat(lines, "\n") .. "\ntrue\n"
end

-- Agent id → path, parsed from the probe's output.
function detect.parse(stdout: string): { [string]: string }
	local out: { [string]: string } = {}
	for _, line in util.lines(stdout) do
		local id, path = string.match(line, "^([^\t]+)\t(.+)$")
		if id ~= nil and path ~= nil then
			local clean = util.clean(path)
			if clean ~= nil then
				out[id] = clean
			end
		end
	end
	return out
end

-- Probes for every agent in `candidates` and caches the result.
-- `cb(cache, err, cx)` runs on the window thread with a fresh `cx`.
function detect.refresh(
	candidates: { { id: string, bin: string } },
	cb: ((Cache?, string?, WindowCx?) -> ())?
)
	if #candidates == 0 then
		if cb then
			cb({ found = {}, at = os.time(), shell = detect.shell() }, nil, nil)
		end
		return
	end
	local shell = detect.shell()
	local argv = { shell, "-lic", detect.script(candidates) }
	local ok, err = pcall(
		tern.process.run,
		argv,
		{ timeout_ms = PROBE_TIMEOUT_MS } :: any,
		function(result: ProcessResult, cx: WindowCx?)
			if result.timed_out then
				if cb then
					cb(nil, "the shell took too long to answer", cx)
				end
				return
			end
			local cache: Cache = {
				found = detect.parse(result.stdout),
				at = os.time(),
				shell = shell,
			}
			pcall(tern.kv.set, KEY, cache)
			if cb then
				cb(cache, nil, cx)
			end
		end
	)
	if not ok and cb then
		cb(nil, tostring(err), nil)
	end
end

-- The candidates of a config: one per agent, its binary (or the program of
-- its command line).
function detect.candidates(agents: { [string]: any }): { { id: string, bin: string } }
	local out: { { id: string, bin: string } } = {}
	for id, agent in agents do
		local bin = util.clean(agent.bin)
		if agent.command ~= nil then
			local words = util.split_args(agent.command)
			bin = util.clean(words[1]) or bin
		end
		if bin ~= nil then
			table.insert(out, { id = id, bin = bin })
		end
	end
	table.sort(out, function(a, b): boolean
		return a.id < b.id
	end)
	return out
end

return detect
