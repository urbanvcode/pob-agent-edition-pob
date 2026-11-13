-- Agent Edition live server.
--
-- Lets AI tools (via pob-mcp) drive the PoB window you are looking at.
-- Speaks the same JSON-lines protocol as pob-mcp's headless stdio bridge and
-- reuses its handlers (pob-mcp/lua/bridge_handlers.lua), so every lua_* MCP
-- tool works against the live GUI build.
--
-- Binds to 127.0.0.1 only. Port: POB_AGENT_PORT (default 31337).
-- Handler dir: POB_AGENT_LUA_DIR (default <repo>/../pob-mcp/lua/).
-- Disable with POB_AGENT_DISABLE=1.

local socket = require("socket")
local json = require("dkjson")

local LiveServer = {
	port = tonumber(os.getenv("POB_AGENT_PORT") or "") or 31337,
	clients = {},
	status = "stopped",
	lastError = nil,
	requests = 0,
}

-- SimpleGraphic skips OnFrame entirely while the window is unfocused and the
-- cursor is elsewhere, unless a coroutine is suspended. We keep one suspended
-- coroutine alive so frames (and this server) keep running, and throttle
-- ourselves with socket.select so an unfocused PoB idles at ~10 fps but wakes
-- instantly when a request arrives.
local windowActive = function() return true end
do
	local ok, ffi = pcall(require, "ffi")
	if ok and ffi.os == "Windows" then
		pcall(ffi.cdef, "void* GetActiveWindow(void);")
		local user32ok, user32 = pcall(ffi.load, "user32")
		if user32ok then
			windowActive = function() return user32.GetActiveWindow() ~= nil end
		end
	end
end

local function log(fmt, ...)
	ConPrintf("[Agent] " .. fmt, ...)
end

local function encode(value)
	local ok, encoded = pcall(json.encode, value)
	if not ok then
		encoded = json.encode({ ok = false, error = "response could not be serialised: " .. tostring(encoded) })
	end
	return encoded .. "\n"
end

local function handlerDir()
	local dir = os.getenv("POB_AGENT_LUA_DIR")
	if not dir or dir == "" then
		-- GetScriptPath() is <repo>/src; pob-mcp sits next to the repo.
		dir = GetScriptPath() .. "/../../pob-mcp/lua/"
	end
	dir = dir:gsub("\\", "/")
	if not dir:match("/$") then dir = dir .. "/" end
	return dir
end

-- One request may need PoB to run a frame first (mode switches happen in
-- main:OnFrame). Such handlers return defer(fn); fn runs on the next poll.
local function defer(fn, frames)
	return { __defer = fn, __frames = frames or 1 }
end

local function buildLoaded()
	return main and main.mode == "BUILD" and build and build.spec and build.savers
end

local function setBuildGlobal()
	if main and main.modes then
		build = main.modes["BUILD"]
	end
end

function LiveServer:LoadHandlers()
	local dir = handlerDir()
	local chunk, err = loadfile(dir .. "bridge_handlers.lua")
	if not chunk then
		return nil, "cannot load handlers from " .. dir .. ": " .. tostring(err)
	end
	local ok, handlers = pcall(chunk, dir)
	if not ok then
		return nil, "handler init failed: " .. tostring(handlers)
	end
	self:AddLiveHandlers(handlers)
	return handlers
end

function LiveServer:AddLiveHandlers(handlers)
	local headlessNewBuild = handlers.new_build

	handlers.version = function()
		return { ok = true, version = {
			number = launch.versionNumber, branch = launch.versionBranch, platform = launch.versionPlatform,
			adapter = "agent-live-v1", edition = "agent",
		} }
	end

	-- What the window is showing right now.
	handlers.get_live_state = function()
		local b = main.modes["BUILD"]
		local inBuild = main.mode == "BUILD"
		return { ok = true, state = {
			mode = main.mode,
			buildName = inBuild and b.buildName or nil,
			file = inBuild and b.dbFileName or nil,
			unsaved = inBuild and (b.unsaved == true),
			viewMode = inBuild and b.viewMode or nil,
			className = inBuild and b.spec and b.spec.curClassName or nil,
			ascendancy = inBuild and b.spec and b.spec.curAscendClassName or nil,
			level = inBuild and b.characterLevel or nil,
			treeVersion = inBuild and b.targetVersion or nil,
			buildsPath = main.buildPath,
		} }
	end

	-- Load XML into the window as a new, unsaved build (headless-compatible).
	handlers.load_build_xml = function(params)
		if type(params.xml) ~= "string" then return { ok = false, error = "missing xml" } end
		main:SetMode("BUILD", false, (params.name and tostring(params.name)) or "Agent Build", params.xml)
		return defer(function()
			setBuildGlobal()
			if not buildLoaded() then
				return { ok = false, error = "PoB did not open the build; check the XML and supported build version" }
			end
			return { ok = true, build_id = 1 }
		end)
	end

	-- Open a saved build file in the window, so Ctrl+S in PoB saves back to it.
	handlers.open_build_file = function(params)
		local path = params.path
		if type(path) ~= "string" or path == "" then return { ok = false, error = "missing path" } end
		path = path:gsub("\\", "/")
		local f = io.open(path, "r")
		if not f then return { ok = false, error = "file not found: " .. path } end
		f:close()
		local name = params.name or path:match("([^/]+)%.xml$") or path
		main:SetMode("BUILD", path, name)
		return defer(function()
			setBuildGlobal()
			if not buildLoaded() then return { ok = false, error = "PoB did not open " .. path } end
			return { ok = true, build_id = 1, file = build.dbFileName, name = build.buildName }
		end)
	end

	handlers.new_build = function(params)
		main:SetMode("BUILD", false, (params and params.name) or "Unnamed build")
		return defer(function()
			setBuildGlobal()
			if not buildLoaded() then return { ok = false, error = "PoB did not create a build" } end
			if params and (params.className or params.ascendancy) then
				local saved = _G.newBuild
				_G.newBuild = function() end -- the build already exists in the window
				local ok, res = pcall(headlessNewBuild, params)
				_G.newBuild = saved
				if not ok then return { ok = false, error = tostring(res) } end
				return res
			end
			return { ok = true }
		end)
	end

	-- Save the window's build to its file (same as Ctrl+S). Optional new path.
	handlers.save_live_build = function(params)
		if not buildLoaded() then return { ok = false, error = "no build open in PoB" } end
		if params and params.path then
			build.dbFileName = tostring(params.path):gsub("\\", "/")
			build.buildName = params.name or build.dbFileName:match("([^/]+)%.xml$") or build.buildName
		end
		if not build.dbFileName then return { ok = false, error = "build has no file yet; pass path" } end
		local ok, err = pcall(build.SaveDBFile, build)
		if not ok then return { ok = false, error = tostring(err) } end
		return { ok = true, file = build.dbFileName }
	end

	-- Switch the visible tab: OVERVIEW, TREE, SKILLS, ITEMS, CALCS, CONFIG, NOTES, IMPORT, PARTY.
	handlers.set_view = function(params)
		if not buildLoaded() then return { ok = false, error = "no build open in PoB" } end
		local view = tostring(params.view or ""):upper()
		local valid = { OVERVIEW = true, ATLAS = true, TREE = true, SKILLS = true, ITEMS = true, CALCS = true, CONFIG = true, NOTES = true, IMPORT = true, PARTY = true, COMPARE = true }
		if not valid[view] then return { ok = false, error = "unknown view: " .. view } end
		build.viewMode = view
		return { ok = true, view = view }
	end

	-- Open the Options popup (e.g. so the player can edit the Agent profile).
	handlers.open_options = function()
		if main.popups[1] then return { ok = false, error = "a popup is already open in PoB" } end
		main:OpenOptionsPopup()
		return { ok = true }
	end

	-- Dev helper: PoB's own full-window screenshot (saved by SimpleGraphic)
	handlers.take_screenshot = function()
		if not TakeScreenshot then return { ok = false, error = "not available" } end
		TakeScreenshot()
		return { ok = true }
	end

	-- Upgrade suggestions from the AI, shown in the Overview's Advisor card.
	handlers.set_advisor = function(params)
		if type(params) ~= "table" or type(params.items) ~= "table" then return { ok = false, error = "items required" } end
		params.buildName = buildLoaded() and build.buildName or nil
		params.receivedAt = os.time()
		main.agentAdvisor = params
		return { ok = true, count = #params.items }
	end

	handlers.get_capabilities = function()
		local actions = {}
		for name in pairs(handlers) do table.insert(actions, name) end
		table.sort(actions)
		return { ok = true, capabilities = { mode = "live", adapter = "agent-live-v1", actions = actions } }
	end
end

function LiveServer:Start()
	if os.getenv("POB_AGENT_DISABLE") == "1" then
		self.status = "disabled"
		return
	end
	local handlers, err = self:LoadHandlers()
	if not handlers then
		self.status, self.lastError = "error", err
		log("handlers unavailable: %s", err)
		return
	end
	self.handlers = handlers
	local server = socket.tcp()
	server:setoption("reuseaddr", true)
	local ok, bindErr = server:bind("127.0.0.1", self.port)
	if ok then ok, bindErr = server:listen(8) end
	if not ok then
		server:close()
		self.status, self.lastError = "error", "port " .. self.port .. ": " .. tostring(bindErr)
		log("could not listen: %s", self.lastError)
		return
	end
	server:settimeout(0)
	self.server = server
	-- Strong reference: PoB tracks coroutines in a weak table.
	self.keepAwake = coroutine.create(function() while true do coroutine.yield() end end)
	coroutine.resume(self.keepAwake)
	self.status = "listening"
	log("listening on 127.0.0.1:%d", self.port)
end

function LiveServer:Send(client, value)
	client.sock:settimeout(5)
	local _, err = client.sock:send(encode(value))
	client.sock:settimeout(0)
	if err then client.dead = true end
end

function LiveServer:Dispatch(client, request)
	if type(request) ~= "table" then
		return { ok = false, error = "invalid request: expected a JSON object" }
	end
	local action, params = request.action, request.params or {}
	if action == "quit" then
		-- Never close the user's PoB; just drop this connection.
		client.closeAfterReply = true
		return { ok = true, quit = true }
	end
	local handler = self.handlers[action]
	if not handler then return { ok = false, error = "unknown action: " .. tostring(action) } end
	setBuildGlobal()
	if action ~= "get_live_state" and action ~= "ping" and action ~= "version" and action ~= "get_capabilities"
		and action ~= "load_build_xml" and action ~= "open_build_file" and action ~= "new_build" and not buildLoaded() then
		return { ok = false, error = "PoB is on the build list; open a build first (or use open_build_file / new_build)" }
	end
	self.requests = self.requests + 1
	local ok, res = pcall(handler, params)
	if not ok then return { ok = false, error = tostring(res) } end
	if type(res) ~= "table" then return { ok = false, error = "handler returned no response" } end
	return res
end

function LiveServer:Finish(client, res)
	if res.__defer then
		client.pending = res
		return false
	end
	self:Send(client, res)
	if client.closeAfterReply then client.dead = true end
	return true
end

-- Called once per frame from launch:OnFrame, before PoB's own frame.
function LiveServer:Poll()
	if not self.server then return end
	local busy = false
	for _, client in ipairs(self.clients) do
		if client.pending then busy = true break end
	end
	if not busy and not windowActive() then
		-- Unfocused: sleep up to 100 ms, waking at once on a connection or request.
		local watch = { self.server }
		for _, client in ipairs(self.clients) do table.insert(watch, client.sock) end
		socket.select(watch, nil, 0.1)
	end
	while true do
		local sock = self.server:accept()
		if not sock then break end
		sock:settimeout(0)
		sock:setoption("tcp-nodelay", true)
		local client = { sock = sock, buf = "" }
		table.insert(self.clients, client)
		self:Send(client, { ok = true, ready = true, version = { adapter = "agent-live-v1", edition = "agent", number = launch.versionNumber } })
	end
	for i = #self.clients, 1, -1 do
		local client = self.clients[i]
		if client.pending then
			local p = client.pending
			p.__frames = p.__frames - 1
			if p.__frames <= 0 then
				client.pending = nil
				setBuildGlobal()
				local ok, res = pcall(p.__defer)
				if not ok then res = { ok = false, error = tostring(res) } end
				if type(res) ~= "table" then res = { ok = false, error = "deferred handler returned no response" } end
				self:Finish(client, res)
			end
		end
		while not client.pending and not client.dead do
			local line, err, partial = client.sock:receive("*l")
			if line then
				line = client.buf .. line
				client.buf = ""
				if line:match("%S") then
					local okDecode, request = pcall(json.decode, line)
					self:Finish(client, self:Dispatch(client, okDecode and request or nil))
				end
			else
				if partial and partial ~= "" then client.buf = client.buf .. partial end
				if err == "closed" then client.dead = true end
				break
			end
		end
		if client.dead then
			client.sock:close()
			table.remove(self.clients, i)
		end
	end
end

function LiveServer:Stop()
	for _, client in ipairs(self.clients) do client.sock:close() end
	self.clients = {}
	if self.server then self.server:close() end
	self.server = nil
	self.keepAwake = nil
	self.status = "stopped"
end

return LiveServer
