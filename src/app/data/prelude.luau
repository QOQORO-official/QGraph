--!nonstrict
-- QGraph script runtime, loaded before every program. It turns the worker's
-- four primitives (__log, __host, __sleep, __now) into the API that script
-- blocks and Luau code use. Document operations are answered by the editor.

local __log, __host, __sleep, __now = __log, __host, __sleep, __now
local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
	["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local unescapes = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f",
	n = "\n", r = "\r", t = "\t" }

-- JSON ------------------------------------------------------------------------

local function quote(s: string): string
	return '"' .. string.gsub(s, '[%c"\\]', function(c)
		return escapes[c] or string.format("\\u%04x", string.byte(c))
	end) .. '"'
end

local function isArray(t): (boolean, number)
	local n = #t
	local count = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return false, 0 end
		count += 1
	end
	return count == n, n
end

local function encode(v: any, seen: { [any]: boolean }): string
	local kind = type(v)
	if v == nil then
		return "null"
	elseif kind == "boolean" then
		return if v then "true" else "false"
	elseif kind == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		if v % 1 == 0 and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
		local short = string.format("%.14g", v)
		return if tonumber(short) == v then short else string.format("%.17g", v)
	elseif kind == "string" then
		return quote(v)
	elseif kind == "table" then
		if seen[v] then error("json.encode: table contains itself", 3) end
		seen[v] = true
		local out = {}
		local array, n = isArray(v)
		local result
		if array and (n > 0 or next(v) == nil) then
			for i = 1, n do out[i] = encode(v[i], seen) end
			result = "[" .. table.concat(out, ",") .. "]"
		else
			for k, value in pairs(v) do
				if type(value) ~= "function" then
					table.insert(out, quote(tostring(k)) .. ":" .. encode(value, seen))
				end
			end
			result = "{" .. table.concat(out, ",") .. "}"
		end
		seen[v] = nil
		return result
	end
	return quote(tostring(v))
end

local function skip(s: string, i: number): number
	local _, e = string.find(s, "^[ \t\r\n]*", i)
	return (e :: number) + 1
end

local function decodeString(s: string, i: number): (string, number)
	local out = {}
	local j = i + 1
	while true do
		local k = string.find(s, '["\\]', j)
		if not k then error("json.decode: unterminated string", 0) end
		table.insert(out, string.sub(s, j, k - 1))
		if string.sub(s, k, k) == '"' then return table.concat(out), k + 1 end
		local c = string.sub(s, k + 1, k + 1)
		if c == "u" then
			local code = tonumber(string.sub(s, k + 2, k + 5), 16) or 63
			j = k + 6
			if code >= 0xD800 and code <= 0xDBFF and string.sub(s, j, j + 1) == "\\u" then
				local low = tonumber(string.sub(s, j + 2, j + 5), 16)
				if low and low >= 0xDC00 and low <= 0xDFFF then
					code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
					j += 6
				end
			end
			table.insert(out, utf8.char(code))
		else
			table.insert(out, unescapes[c] or c)
			j = k + 2
		end
	end
end

local function decodeValue(s: string, i: number): (any, number)
	i = skip(s, i)
	local c = string.sub(s, i, i)
	if c == "{" then
		local t = {}
		i = skip(s, i + 1)
		if string.sub(s, i, i) == "}" then return t, i + 1 end
		while true do
			local key
			key, i = decodeString(s, skip(s, i))
			i = skip(s, i)
			if string.sub(s, i, i) ~= ":" then error("json.decode: expected ':'", 0) end
			local value
			value, i = decodeValue(s, i + 1)
			t[key] = value
			i = skip(s, i)
			local d = string.sub(s, i, i)
			if d == "}" then return t, i + 1 end
			if d ~= "," then error("json.decode: expected ',' or '}'", 0) end
			i += 1
		end
	elseif c == "[" then
		local t = {}
		local n = 0
		i = skip(s, i + 1)
		if string.sub(s, i, i) == "]" then return t, i + 1 end
		while true do
			local value
			value, i = decodeValue(s, i)
			n += 1
			t[n] = value
			i = skip(s, i)
			local d = string.sub(s, i, i)
			if d == "]" then return t, i + 1 end
			if d ~= "," then error("json.decode: expected ',' or ']'", 0) end
			i += 1
		end
	elseif c == '"' then
		return decodeString(s, i)
	elseif string.sub(s, i, i + 3) == "true" then
		return true, i + 4
	elseif string.sub(s, i, i + 4) == "false" then
		return false, i + 5
	elseif string.sub(s, i, i + 3) == "null" then
		return nil, i + 4
	end
	local _, e = string.find(s, "^-?[%d%.eE%+%-]+", i)
	if not e then error("json.decode: unexpected '" .. c .. "'", 0) end
	return tonumber(string.sub(s, i, e)), e + 1
end

json = table.freeze({
	encode = function(value: any): string return encode(value, {}) end,
	decode = function(text: string): any return (decodeValue(text, 1)) end,
})

-- Formatting and output -------------------------------------------------------

local function describe(v: any, depth: number, seen: { [any]: boolean }): string
	if type(v) == "string" then return if depth == 0 then v else string.format("%q", v) end
	if type(v) ~= "table" then return tostring(v) end
	if seen[v] then return "{…}" end
	if depth >= 3 then return "{…}" end
	seen[v] = true
	local parts = {}
	local array, n = isArray(v)
	if array then
		for i = 1, math.min(n, 50) do table.insert(parts, describe(v[i], depth + 1, seen)) end
		if n > 50 then table.insert(parts, "…") end
	else
		local keys = {}
		for k in pairs(v) do table.insert(keys, k) end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for i, k in keys do
			if i > 50 then table.insert(parts, "…") break end
			local key = if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then k
				else "[" .. describe(k, depth + 1, seen) .. "]"
			table.insert(parts, key .. " = " .. describe(v[k], depth + 1, seen))
		end
	end
	seen[v] = nil
	return "{" .. table.concat(parts, ", ") .. "}"
end

local function show(...: any): string
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = describe((select(i, ...)), 0, {}) end
	return table.concat(parts, "\t")
end

inspect = function(value: any): string return describe(value, 1, {}) end

local function call(op: string, args: any): any
	local reply = json.decode(__host(op, json.encode(args)))
	if type(reply) ~= "table" then error("editor: bad reply to " .. op, 2) end
	if reply.ok then return reply.value end
	error(reply.error or ("editor: " .. op .. " failed"), 3)
end

print = function(...: any) __log("print", show(...)) end
warn = function(...: any) __log("warn", show(...)) end
info = function(...: any) __log("info", show(...)) end

alert = function(...: any) call("alert", { text = show(...) }) end
confirm = function(...: any): boolean return call("confirm", { text = show(...) }) == true end
prompt = function(message: any?, default: any?): string?
	return call("prompt", { text = if message == nil then "" else tostring(message),
		default = if default == nil then "" else tostring(default) })
end
toast = function(...: any) call("toast", { text = show(...) }) end

-- Blocks run until they wait; the program counts steps between waits to
-- catch flows that loop forever without pausing.
__steps = 0

wait = function(seconds: number?): number
	local start = __now()
	__sleep(seconds or 0)
	__steps = 0
	return (__now() - start) / 1000
end
task = table.freeze({ wait = wait })
clock = function(): number return __now() / 1000 end

-- The block that is running (set by the program before each block).
block = nil :: string?

-- Shows `value` as a block's output: "block" writes it on the block itself,
-- "console" prints it, "alert" opens a browser alert.
output = function(value: any, mode: string?, target: string?)
	local text = show(value)
	local how = mode or "block"
	if how == "console" then
		__log("print", text)
	elseif how == "alert" then
		call("alert", { text = text })
	else
		call("output", { id = target or block, text = text })
	end
end

-- Reports a failing block to the editor and ends the run.
__fail = function(id: string, err: any)
	call("fail", { id = id, error = tostring(err) })
	error("__qgraph_block_failed__", 0)
end

-- The document ----------------------------------------------------------------

local function ids(v: any): { string }
	if type(v) == "table" then
		if v.id then return { v.id } end
		local out = {}
		for i, x in v do out[i] = if type(x) == "table" then x.id else x end
		return out
	end
	return { v }
end

local function idOf(v: any): string
	return if type(v) == "table" then v.id else v
end

doc = table.freeze({
	-- Plain snapshots of items (tables with id, text, x, y, width, height, …).
	nodes = function(): { any } return call("nodes", {}) end,
	edges = function(): { any } return call("edges", {}) end,
	get = function(id: any): any? return call("get", { id = idOf(id) }) end,
	find = function(text: string): any? return call("find", { text = text }) end,
	findAll = function(text: string): { any } return call("findAll", { text = text }) end,
	selection = function(): { any } return call("selection", {}) end,
	neighbors = function(id: any, direction: string?): { any }
		return call("neighbors", { id = idOf(id), direction = direction or "out" })
	end,
	-- Changes; the whole run is one undo step.
	set = function(id: any, props: { [string]: any }): any
		return call("set", { id = idOf(id), props = props })
	end,
	setText = function(id: any, text: any): any
		return call("set", { id = idOf(id), props = { text = tostring(text) } })
	end,
	add = function(props: { [string]: any }?): any return call("add", { props = props or {} }) end,
	connect = function(from: any, to: any, props: { [string]: any }?): any
		return call("connect", { source = idOf(from), target = idOf(to), props = props or {} })
	end,
	remove = function(target: any): number return call("remove", { ids = ids(target) }) end,
	select = function(target: any?): number
		return call("select", { ids = if target == nil then {} else ids(target) })
	end,
	fit = function() call("fit", {}) end,
})
