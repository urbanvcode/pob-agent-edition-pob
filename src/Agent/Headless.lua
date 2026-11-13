-- Agent Edition headless runner.
--
-- Runs PoB without a window and answers JSON lines on stdin/stdout with the
-- same handlers the live window uses (Agent/Handlers/). agent-mcp starts it
-- when no PoB Agent Edition window is open, and for comparing saved builds.
--
-- Based on ianderse/pob-mcp (https://github.com/ianderse/pob-mcp, GPL-3.0), original file: lua/vanilla_stdio_bridge.lua
-- (JSON-lines loop and the real Inflate through zlib).
--
-- Run with the working directory set to src/:  luajit Agent/Headless.lua
-- LUA_PATH must include ../runtime/lua/?.lua (dkjson, xml, ...).
local json = require('dkjson')

if not GetVirtualScreenSize then
	function GetVirtualScreenSize() return 1920, 1080 end
end

-- HeadlessWrapper prints PoB's console output; keep stdout for JSON only.
local realPrint = print
print = function(...)
	local parts = {}
	for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
	io.stderr:write(table.concat(parts, '\t'), '\n')
end

-- HeadlessWrapper hides lcurl from require(); tree packs (Agent/TreePacks.lua) need it, so keep the real one.
AgentRealRequire = require
dofile('HeadlessWrapper.lua')

-- HeadlessWrapper's MakeDir does nothing; tree packs (Agent/TreePacks.lua) need real folders.
do
	local ok, ffi = pcall(require, 'ffi')
	if ok and pcall(ffi.cdef, 'int _mkdir(const char *path);') then
		MakeDir = function(path)
			local p = tostring(path):gsub('[/\\]+', '/')
			local acc = p:sub(1, 1) == '/' and '/' or ''
			for part in p:gmatch('[^/]+') do
				acc = (acc == '' or acc == '/') and (acc .. part) or (acc .. '/' .. part)
				if not part:match(':$') then pcall(ffi.C._mkdir, acc) end
			end
		end
	end
end

-- HeadlessWrapper stubs Inflate() to return "", which makes PoB's timeless
-- jewel loader overwrite its .bin cache with an empty file. Provide the real
-- thing through zlib (shipped in runtime/).
do
	local ok, err = pcall(function()
		local ffi = require('ffi')
		ffi.cdef[[
			int uncompress(uint8_t *dest, unsigned long *destLen, const uint8_t *source, unsigned long sourceLen);
		]]
		local zlib
		for _, name in ipairs({ '../runtime/zlib1.dll', 'zlib1', 'z', 'libz.so.1', 'libz.dylib' }) do
			local loaded, lib = pcall(ffi.load, name)
			if loaded then zlib = lib break end
		end
		if not zlib then error('zlib not found') end
		function Inflate(data)
			if not data or #data == 0 then return '' end
			local size = math.max(#data * 4, 65536)
			while size <= 1024 * 1024 * 1024 do
				local buf = ffi.new('uint8_t[?]', size)
				local len = ffi.new('unsigned long[1]', size)
				local rc = zlib.uncompress(buf, len, data, #data)
				if rc == 0 then return ffi.string(buf, len[0]) end
				if rc ~= -5 then return '' end -- Z_BUF_ERROR: grow and retry
				size = size * 2
			end
			return ''
		end
	end)
	if not ok then
		-- Without a real Inflate the timeless jewel caches would be zeroed: refuse to run.
		io.stderr:write('Agent/Headless.lua: zlib unavailable (' .. tostring(err) .. ')\n')
		io.write(json.encode({ ok = false, ready = false, error = 'zlib not found; cannot run headless safely' }), '\n')
		io.flush()
		os.exit(1)
	end
end

local function reply(value)
	local ok, encoded = pcall(json.encode, value)
	if not ok then
		encoded = json.encode({ ok = false, error = 'response could not be serialised: ' .. tostring(encoded) })
	end
	io.write(encoded, '\n')
	io.flush()
end

local DIR = 'Agent/Handlers/'
local handlers = loadfile(DIR .. 'Core.lua')(DIR)

reply({ ok = true, ready = true, version = { adapter = 'agent-headless-v1', edition = 'agent', number = launch and launch.versionNumber } })
for line in io.lines() do
	local request = json.decode(line)
	if type(request) ~= 'table' then
		reply({ ok = false, error = 'invalid request: expected a JSON object' })
	else
		local action, params = request.action, request.params or {}
		if action == 'quit' then
			reply({ ok = true, quit = true })
			break
		end
		local handler = handlers[action]
		if not handler then
			reply({ ok = false, error = 'unknown action: ' .. tostring(action) })
		else
			local ok, res = pcall(handler, params)
			if not ok then
				reply({ ok = false, error = tostring(res) })
			elseif type(res) ~= 'table' then
				reply({ ok = false, error = 'handler returned no response' })
			else
				reply(res)
			end
		end
	end
end
