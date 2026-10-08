--!strict
-- Pure string, path and shell helpers shared by both halves. No `tern` calls,
-- so the test runner can load this module with plain `luau`.

local util = {}

-- `s` without leading and trailing whitespace.
function util.trim(s: string): string
	return (string.match(s, "^%s*(.-)%s*$") or "")
end

-- `path` without trailing slashes ("/" stays "/").
function util.strip_slash(path: string): string
	local out = string.gsub(path, "(.)/+$", "%1")
	return out
end

-- Last path component.
function util.basename(path: string): string
	local p = util.strip_slash(path)
	return string.match(p, "([^/]+)$") or p
end

-- An absolute path with `.` and `..` components resolved lexically.
function util.normalize(path: string): string
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

-- `path` resolved against directory `base` (absolute paths win; `~` uses `home`).
function util.resolve(base: string, path: string, home: string?): string
	if (path == "~" or string.sub(path, 1, 2) == "~/") and home then
		return util.normalize(home .. string.sub(path, 2))
	end
	if string.sub(path, 1, 1) == "/" then
		return util.normalize(path)
	end
	return util.normalize(base .. "/" .. path)
end

-- Whether `path` is `root` or lies under it.
function util.inside(path: string?, root: string): boolean
	if path == nil or path == "" then
		return false
	end
	local p = util.strip_slash(path)
	local r = util.strip_slash(root)
	return p == r or r == "/" or string.sub(p, 1, #r + 1) == r .. "/"
end

-- `path` with the home directory shown as `~`.
function util.tilde(path: string, home: string?): string
	if home and home ~= "" and util.inside(path, home) then
		return "~" .. string.sub(path, #util.strip_slash(home) + 1)
	end
	return path
end

-- `s` quoted for POSIX shells (single quotes, with `'` spliced).
function util.shell_quote(s: string): string
	if s ~= "" and string.match(s, "^[%w%._/%-=:@,+]+$") then
		return s
	end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- `s` escaped for the inside of a double-quoted shell string, so
-- `zsh -lic "exec <s>"` runs `<s>` and nothing else: the shell still expands
-- `$`, backticks and `\` there, and `"` would end the string.
function util.dquote_escape(s: string): string
	local out = string.gsub(s, "[\\\"$`]", "\\%0")
	return out
end

-- `line` split into words the way a shell would: whitespace separates, and
-- single or double quotes keep a run together. Quotes are consumed, so
-- `-c model="high"` becomes `{"-c", "model=high"}`, and the caller re-quotes.
-- Unbalanced quotes end at the end of the line rather than raising.
function util.split_args(line: string): { string }
	local out: { string } = {}
	local word: { string } = {}
	local quote: string? = nil
	local started = false
	local i = 1
	while i <= #line do
		local c = string.sub(line, i, i)
		if quote ~= nil then
			if c == quote then
				quote = nil
			elseif c == "\\" and quote == '"' and i < #line then
				i += 1
				table.insert(word, string.sub(line, i, i))
			else
				table.insert(word, c)
			end
		elseif c == "'" or c == '"' then
			quote = c
			started = true
		elseif c == "\\" and i < #line then
			i += 1
			table.insert(word, string.sub(line, i, i))
			started = true
		elseif string.match(c, "%s") then
			if started then
				table.insert(out, table.concat(word))
				word = {}
				started = false
			end
		else
			table.insert(word, c)
			started = true
		end
		i += 1
	end
	if started then
		table.insert(out, table.concat(word))
	end
	return out
end

-- `words` joined back into a shell line, each word quoted when it needs it.
function util.join_args(words: { string }): string
	local out: { string } = {}
	for _, w in words do
		table.insert(out, util.shell_quote(w))
	end
	return table.concat(out, " ")
end

-- A short human age for `seconds` ("just now", "4m", "2h", "3d").
function util.age(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	if s < 45 then
		return "just now"
	elseif s < 3600 then
		return tostring(math.floor(s / 60)) .. "m"
	elseif s < 86400 then
		return tostring(math.floor(s / 3600)) .. "h"
	end
	return tostring(math.floor(s / 86400)) .. "d"
end

-- An id-safe slug: lowercase, letters, digits, `.`, `_` and `-`.
function util.slug(text: string): string
	local s = string.lower(util.trim(text))
	s = string.gsub(s, "[^%w%._%-]+", "-")
	s = string.gsub(s, "%-%-+", "-")
	s = string.gsub(s, "^[%-%.]+", "")
	s = string.gsub(s, "%-+$", "")
	return s
end

-- `s` cut to `n` characters, with an ellipsis when it was longer.
function util.clip(s: string, n: number): string
	if #s <= n then
		return s
	end
	return string.sub(s, 1, math.max(1, n - 1)) .. "…"
end

-- A trimmed string, or nil for anything else and for blanks.
function util.clean(value: any): string?
	if type(value) ~= "string" then
		return nil
	end
	local trimmed = util.trim(value)
	return if trimmed == "" then nil else trimmed
end

-- A list of strings from a string (split like a shell line) or an array.
-- Anything else, and any non-string item, is ignored.
function util.string_list(value: any): { string }
	if type(value) == "string" then
		return util.split_args(value)
	end
	if type(value) ~= "table" then
		return {}
	end
	local out: { string } = {}
	for _, item in value do
		if type(item) == "string" then
			table.insert(out, item)
		end
	end
	return out
end

-- A `{[string]: string}` map from a table of scalars; other values are dropped.
function util.env_map(value: any): { [string]: string }
	local out: { [string]: string } = {}
	if type(value) ~= "table" then
		return out
	end
	for k, v in value do
		if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then
			if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
				out[k] = tostring(v)
			end
		end
	end
	return out
end

-- `a` with `b`'s entries laid over it (a new table; neither input changes).
function util.merge(a: { [string]: any }?, b: { [string]: any }?): { [string]: any }
	local out: { [string]: any } = {}
	for k, v in a or {} do
		out[k] = v
	end
	for k, v in b or {} do
		out[k] = v
	end
	return out
end

-- How many UTF-16 code units `s` holds. Tern's `input` node counts its
-- `cursor` and `anchor` in UTF-16 units, while Luau strings are bytes, so a
-- block that edits by byte offset has to convert before drawing. Text that
-- isn't valid UTF-8 (a half-pasted character) falls back to its byte length,
-- which is what the caret was doing anyway.
function util.utf16_units(s: string): number
	local ok, n = pcall(function(): number
		local count = 0
		for _, code in utf8.codes(s) do
			count += if code > 0xFFFF then 2 else 1
		end
		return count
	end)
	return if ok then n else #s
end

-- Lines of `text`, without trailing carriage returns.
function util.lines(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text, "[^\n]+") do
		local clean = string.gsub(line, "\r$", "")
		table.insert(out, clean)
	end
	return out
end

return util
