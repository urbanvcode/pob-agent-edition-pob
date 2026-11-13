-- PoB Agent Edition: AI chat inside PoB (Stage 10), the state behind the panel.
-- Runs agent-mcp's chat bridge (agent-mcp/build/chat/bridge.js) in the background
-- (Agent/ChatProcess.lua), streams its JSON-line events into the conversation of
-- the open build, and keeps one conversation (and backend session) per build in
-- <user folder>/AgentCache/chat/builds/. The backends use the same pob tools and
-- rules as external AI apps; this file never sees an API key (the bridge reads it).
-- Settings in AgentEdition.json: chat = { backend, allowEdits, open } and
-- anthropicApiKey (written by Options, never shown again).

local AgentSettings = LoadModule("Agent/Settings")
local Update = LoadModule("Agent/Update")
local Proc = LoadModule("Agent/ChatProcess")
local dkjson = require("dkjson")
local t_insert, t_remove = table.insert, table.remove

local Chat = { }

Chat.BACKENDS = {
	{ value = "claude", label = "Claude Code", desc = "Claude Code CLI with your own Claude login (Pro/Max subscription). Sign in once with the Sign in button." },
	{ value = "codex", label = "Codex", desc = "OpenAI Codex CLI with your own ChatGPT login. Sign in once with the Sign in button." },
	{ value = "api", label = "Anthropic API key", desc = "Anthropic Messages API with your own API key (billed per token by Anthropic)." },
}
Chat.QUICK = {
	{ label = "Why am I dying?", text = "Why am I dying? Check my defences and tell me the top fixes." },
	{ label = "Next upgrade", text = "What is my best next upgrade for my budget and play mode?" },
	{ label = "Weak at bosses?", text = "Why am I weak at bosses?" },
}
local MAX_MESSAGES = 60

Chat.messages = { }
Chat.busy = false

local function userPath() return main and main.userPath or "" end

-- Settings ---------------------------------------------------------------------
-- Read from disk at most every 2 s (the panel asks many times per frame).
local cached, cachedAt = nil, -1e9
function Chat.settings()
	local now = GetTime and GetTime() or 0
	if cached and now - cachedAt < 2000 then return cached end
	local s = AgentSettings.get(userPath(), "chat")
	s = type(s) == "table" and s or { }
	if s.backend ~= "codex" and s.backend ~= "api" then s.backend = "claude" end
	s.allowEdits = s.allowEdits == true
	cached, cachedAt = s, now
	return s
end

function Chat.setSetting(key, value)
	cached = nil
	local s = Chat.settings()
	s[key] = value
	AgentSettings.set(userPath(), "chat", s)
	cached, cachedAt = s, GetTime and GetTime() or 0
end

function Chat.backendLabel(value)
	return AgentSettings.label(Chat.BACKENDS, value or Chat.settings().backend)
end

-- The API key is written here and never read back into the UI.
function Chat.setApiKey(key)
	key = tostring(key or ""):gsub("%s", "")
	AgentSettings.set(userPath(), "anthropicApiKey", key ~= "" and key or nil)
end
function Chat.hasApiKey()
	local k = AgentSettings.get(userPath(), "anthropicApiKey")
	return type(k) == "string" and #k >= 20
end

-- Helper process -----------------------------------------------------------------
local function root() return (Update.root():gsub("\\", "/")) end
local function exists(p) local f = io.open(p, "rb") if f then f:close() return true end return false end

function Chat.bridgePath() return root() .. "/agent-mcp/build/chat/bridge.js" end
local function nodeExe()
	local bundled = root() .. "/node/node.exe"
	return exists(bundled) and bundled or "node"
end

function Chat.available()
	if not Proc.available() then return false, "The AI chat needs Windows." end
	if not exists(Chat.bridgePath()) then return false, "The chat helper is missing (agent-mcp/build). Run Install.cmd again." end
	return true
end

local function startBridge(args)
	local cmd = Proc.quote(nodeExe()) .. " " .. Proc.quote(Chat.bridgePath())
	for _, a in ipairs(args or { }) do cmd = cmd .. " " .. Proc.quote(a) end
	return Proc.start(cmd, root())
end

-- Backend check (found / signed in), run in the background once per session.
Chat.check = nil
local checkProc
function Chat.refreshCheck()
	if checkProc or not Chat.available() then return end
	checkProc = startBridge({ "--check" })
	if checkProc then checkProc:closeInput() Chat.checking = true end
end

function Chat.login(backend)
	local p = startBridge({ "--login", backend })
	if p then p:closeInput() end
	-- Re-check a little later: the sign-in happens in its own window.
	Chat.check, Chat.recheckAt = nil, (GetTime and GetTime() or 0) + 15000
end

-- Conversations (one per build) -----------------------------------------------------
local function buildKey(build)
	local name = build and build.buildName or ""
	if name == "" then name = "Unnamed build" end
	return name
end
local function convFile(key)
	return userPath() .. "AgentCache/chat/builds/" .. key:gsub("[^%w%-_ ]", "_") .. ".json"
end
local function mkdirs(path)
	local acc = ""
	for part in path:gmatch("[^/]+/") do
		acc = acc .. part
		if MakeDir then pcall(MakeDir, acc) end
	end
end

function Chat.load(build)
	local key = buildKey(build)
	if Chat.key == key then return end
	Chat.key = key
	Chat.messages, Chat.sessions = { }, { }
	local f = io.open(convFile(key), "r")
	if f then
		local ok, data = pcall(dkjson.decode, f:read("*a"))
		f:close()
		if ok and type(data) == "table" then
			Chat.messages = type(data.messages) == "table" and data.messages or { }
			Chat.sessions = type(data.sessions) == "table" and data.sessions or { }
		end
	end
	Chat.revision = (Chat.revision or 0) + 1
end

function Chat.save()
	if not Chat.key then return end
	while #Chat.messages > MAX_MESSAGES do t_remove(Chat.messages, 1) end
	local file = convFile(Chat.key)
	mkdirs(file)
	local f = io.open(file, "w")
	if not f then return end
	local clean = { }
	for _, m in ipairs(Chat.messages) do
		t_insert(clean, { role = m.role, text = m.text, tools = m.tools, error = m.error, cancelled = m.cancelled, backend = m.backend })
	end
	f:write(dkjson.encode({ messages = clean, sessions = Chat.sessions }))
	f:close()
end

function Chat.newChat()
	if Chat.busy then Chat.cancel() end
	Chat.messages, Chat.sessions = { }, { }
	Chat.revision = (Chat.revision or 0) + 1
	Chat.save()
end

-- Context passed with every message ------------------------------------------------------
local function guideLine(build)
	local f = io.open(userPath() .. "AgentCache/guide/card.json", "r")
	if not f then return nil end
	local ok, data = pcall(dkjson.decode, f:read("*a"))
	f:close()
	if ok and type(data) == "table" and data.guide and data.build == build.buildName then
		return string.format("Guide: %s, stage %s", tostring(data.guide), tostring(data.stage or "?"))
	end
end

local function mainSkill(build)
	local env = build.calcsTab and build.calcsTab.mainEnv
	local skill = env and env.player and env.player.mainSkill
	local effect = skill and skill.activeEffect and skill.activeEffect.grantedEffect
	return effect and effect.name
end

function Chat.context(build)
	local L = { }
	local spec = build.spec
	t_insert(L, string.format("Build open in PoB: \"%s\" | %s%s level %s | main skill: %s",
		buildKey(build), tostring(spec and spec.curClassName or "?"),
		(spec and spec.curAscendClassName and spec.curAscendClassName ~= "None") and (" / " .. spec.curAscendClassName) or "",
		tostring(build.characterLevel or "?"), tostring(mainSkill(build) or "none")))
	t_insert(L, string.format("The player is looking at the %s tab.%s", tostring(build.viewMode or "?"), build.unsaved and " The build has unsaved changes." or ""))
	local p = AgentSettings.getProfile(userPath())
	local cur = p.currency or { }
	t_insert(L, string.format("Player profile: %s %s | league: %s | currency: %s | explanation mode: %s | experience: %s%s",
		AgentSettings.label(AgentSettings.PLAY_MODES, p.playMode), p.hardcore and "Hardcore" or "Softcore",
		p.league ~= "" and p.league or "current league",
		((cur.chaos or 0) > 0 or (cur.divine or 0) > 0) and string.format("%dc %ddiv", cur.chaos or 0, cur.divine or 0) or "not set",
		AgentSettings.label(AgentSettings.EXPLANATION_MODES, p.explanationMode), AgentSettings.label(AgentSettings.EXPERIENCE, p.experience),
		#p.goals > 0 and (" | goals: " .. table.concat(p.goals, "; ")) or ""))
	local g = guideLine(build)
	if g then t_insert(L, g) end
	t_insert(L, "AI may edit the build: " .. (Chat.settings().allowEdits and "on" or "off"))
	return table.concat(L, "\n")
end

-- Sending and streaming ------------------------------------------------------------------
local proc, current

function Chat.send(build, text)
	text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if text == "" or Chat.busy then return false end
	local okAvail, why = Chat.available()
	Chat.load(build)
	t_insert(Chat.messages, { role = "user", text = text })
	current = { role = "ai", text = "", tools = { }, pending = true, backend = Chat.settings().backend }
	t_insert(Chat.messages, current)
	Chat.revision = (Chat.revision or 0) + 1
	if not okAvail then
		current.error, current.pending = why, nil
		Chat.save()
		return false
	end
	local s = Chat.settings()
	local req = {
		backend = s.backend,
		message = text,
		context = Chat.context(build),
		session = Chat.sessions[s.backend],
		allowEdits = s.allowEdits,
		port = launch.agentServer and launch.agentServer.server and launch.agentServer.port or nil,
	}
	local err
	proc, err = startBridge()
	if not proc then
		current.error, current.pending = err, nil
		Chat.save()
		return false
	end
	proc:write(dkjson.encode(req) .. "\n")
	proc:closeInput()
	Chat.busy = true
	Chat.startedAt = GetTime and GetTime() or 0
	return true
end

function Chat.cancel()
	if proc then proc:kill() proc = nil end
	if current then
		current.pending, current.cancelled, current.activity = nil, true, nil
		current = nil
	end
	Chat.busy = false
	Chat.revision = (Chat.revision or 0) + 1
	Chat.save()
end

local function handle(e)
	if type(e) ~= "table" or not current then return end
	if e.t == "text" then
		current.text = current.text .. tostring(e.text or "")
		current.activity = nil
	elseif e.t == "tool" then
		t_insert(current.tools, { name = tostring(e.name), running = true })
		current.activity = "using " .. tostring(e.name)
	elseif e.t == "tool_end" then
		for i = #current.tools, 1, -1 do
			local tl = current.tools[i]
			if tl.running and tl.name == e.name then tl.running, tl.ok = nil, e.ok ~= false break end
		end
		current.activity = "thinking"
	elseif e.t == "session" then
		if e.id then Chat.sessions[current.backend] = e.id end
	elseif e.t == "status" then
		current.activity = tostring(e.text or "")
	elseif e.t == "error" then
		current.error = tostring(e.text or "error")
		current.errorCode = e.code
		if e.code == "not_signed_in" or e.code == "not_found" then Chat.check = nil end
		-- A session the backend no longer knows: start fresh next time.
		if e.code == "failed" and Chat.sessions[current.backend] and current.text == "" then Chat.sessions[current.backend] = nil end
	elseif e.t == "done" then
		if e.session then Chat.sessions[current.backend] = e.session end
	end
	Chat.revision = (Chat.revision or 0) + 1
end

-- Called every frame by Build.lua (also while the panel is hidden).
function Chat.tick()
	if checkProc then
		for _, line in ipairs(checkProc:poll()) do
			local ok, data = pcall(dkjson.decode, line)
			if ok and type(data) == "table" and data.api then Chat.check = data end
		end
		if not checkProc.running then checkProc, Chat.checking = nil, nil end
	elseif Chat.recheckAt and GetTime and GetTime() > Chat.recheckAt then
		Chat.recheckAt = nil
		Chat.refreshCheck()
	end
	if not proc then return end
	local lines = proc:poll()
	for _, line in ipairs(lines) do
		local ok, e = pcall(dkjson.decode, line)
		if ok and type(e) == "table" and e.t then
			handle(e)
		elseif line:match("%S") and current then
			current.raw = line:sub(1, 300) -- not an event (a crash message): kept for the error text
		end
	end
	if not proc.running then
		if current then
			current.pending, current.activity = nil, nil
			if current.text == "" and not current.error then
				current.error = current.raw and ("The chat helper stopped: " .. current.raw) or "No answer came back."
			end
			current = nil
		end
		proc = nil
		Chat.busy = false
		Chat.revision = (Chat.revision or 0) + 1
		Chat.save()
	end
end

-- Preview and apply a suggestion: PoB's own what_if (rolled back) and edit handlers --------
local function dispatch(action, params)
	local server = launch.agentServer
	if not (server and server.handlers) then return { ok = false, error = "PoB's agent API is not running" } end
	return server:Dispatch({ }, { action = action, params = params })
end

function Chat.preview(ops) return dispatch("what_if", { ops = ops }) end
function Chat.apply(ops) return dispatch("edit", { ops = ops }) end

-- Live API actions for tests and automation (127.0.0.1 only, like every live action; not MCP tools):
--   chat_send { message }  types a message into the panel of the open build
--   chat_state { last }    the conversation (last N messages) and whether an answer is running
function Chat.registerLive()
	local server = launch and launch.agentServer
	if not (server and server.handlers) or server.handlers.chat_send then return end
	server.handlers.chat_send = function(params)
		if Chat.busy then return { ok = false, error = "an answer is still running" } end
		local okSend = Chat.send(build, tostring(params.message or ""))
		return { ok = okSend, backend = Chat.settings().backend, error = not okSend and (Chat.messages[#Chat.messages] or { }).error or nil }
	end
	server.handlers.chat_state = function(params)
		Chat.load(build)
		local last, out = tonumber(params.last) or 2, { }
		for i = math.max(1, #Chat.messages - last + 1), #Chat.messages do
			local m = Chat.messages[i]
			local tools = { }
			for _, tl in ipairs(m.tools or { }) do t_insert(tools, tl.name .. (tl.ok == false and "!" or "")) end
			t_insert(out, { role = m.role, text = m.text, tools = tools, error = m.error, pending = m.pending, backend = m.backend })
		end
		return { ok = true, busy = Chat.busy, messages = out }
	end
end

return Chat
