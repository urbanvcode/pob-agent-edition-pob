-- Agent Edition: character sync from inside PoB (Guide tab button, optional auto-sync).
-- Same result as agent-mcp's character_sync (Stage 2), without an AI app:
--   1. the character list, the items and the passive tree from the player's public
--      pathofexile.com profile (the same 3 requests PoB's own Import tab makes),
--      at least 2 s apart, never more than one sync a minute, and a 10-minute pause
--      when pathofexile.com asks for one (HTTP 429);
--   2. PoB's own importer (handler character_import) into the open "<character> - synced" build;
--   3. a history entry in AgentCache/history in the format agent-mcp writes, so the
--      Progress card and character_history show it.
-- The first sync (account and character names) is done once through the AI app or
-- PoB's Import tab; after that the names come from AgentCache/history/index.json.
-- Read-only, no login, no game-client access.
local dkjson = require("dkjson")
local AgentSettings = LoadModule("Agent/Settings")

local Sync = {
	status = nil,       -- last message for the UI
	ok = nil,           -- true / false after a sync
	busy = false,
	lastAt = 0,         -- os.time() of the last sync started here
	blockedUntil = 0,   -- os.time() until which pathofexile.com asked for a pause
}

local HOST = "https://www.pathofexile.com/"
local GAP_MS = 2000
local MIN_RESYNC_S = 60
local AUTO_MINUTES = 15
local PAUSE_S = 600
local MAX_ENTRIES, MAX_SNAPSHOTS = 200, 30

-- Files -----------------------------------------------------------------------------
local function historyDir()
	return (main and main.userPath or "") .. "AgentCache/history/"
end

local function readJson(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	local ok, data = pcall(dkjson.decode, text)
	return ok and type(data) == "table" and data or nil
end

local function writeJson(path, value)
	local tmp = path .. ".tmp"
	local f = io.open(tmp, "w")
	if not f then return false end
	f:write(dkjson.encode(value))
	f:close()
	os.remove(path)
	return os.rename(tmp, path)
end

local function safe(s)
	return (tostring(s or ""):gsub("[^%w%._%-]+", "_")):sub(1, 80)
end

local function urlencode(str)
	return (tostring(str):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- Which character: the last one synced (agent-mcp writes index.last).
function Sync.target()
	local index = readJson(historyDir() .. "index.json") or {}
	return index.last, index
end

-- The open build must be that character's build: a sync replaces items, skills and tree.
function Sync.check(build)
	local last = Sync.target()
	if not last or not last.account or not last.character then
		return false, "Sync your character once through your AI app (\"sync my character\") or PoB's Import tab; after that this button does it."
	end
	local hash = build.importTab and build.importTab.lastCharacterHash
	local mine = build.buildName == last.character .. " - synced" or (hash and hash == common.sha1(last.character))
	if not mine then
		return false, "Open \"" .. last.character .. " - synced\" to sync it (a sync replaces items, skills and tree)."
	end
	return true, last
end

-- Settings: auto-sync on/off (AgentEdition.json, key autoSync).
function Sync.autoEnabled()
	local ok, v = pcall(AgentSettings.get, main.userPath, "autoSync")
	return ok and v == true
end

function Sync.setAuto(on)
	pcall(AgentSettings.set, main.userPath, "autoSync", on and true or false)
end

-- Requests ----------------------------------------------------------------------------
local queue = {}      -- functions waiting for their turn
local nextAt = 0      -- GetTime() of the next allowed request

local function request(url, done)
	table.insert(queue, function()
		launch:DownloadPage(url, function(response, errMsg)
			done(response and response.body, errMsg, response and response.header)
		end, { header = "Accept: application/json" })
	end)
end

-- Called every frame (Build.lua): runs queued requests 2 s apart and starts auto-syncs.
function Sync.tick(build)
	local now = GetTime()
	if #queue > 0 and now >= nextAt then
		local fn = table.remove(queue, 1)
		nextAt = now + GAP_MS
		fn()
	end
	if not Sync.busy and build and Sync.autoEnabled() and os.time() >= Sync.blockedUntil then
		local last = Sync.lastEntryTime()
		if last and os.time() - last >= AUTO_MINUTES * 60 and os.time() - Sync.lastAt >= AUTO_MINUTES * 60 then
			local ok = Sync.check(build)
			if ok and not build.modFlag then Sync.start(build, true) end
		end
	end
end

-- Time of the newest history entry of the target character (os.time), or nil.
function Sync.lastEntryTime()
	local last, index = Sync.target()
	if not last then return nil end
	local entry = index.characters and index.characters[common.sha1(last.character)]
	local point = entry and entry.timeline and entry.timeline[#entry.timeline]
	local at = point and point.at
	if type(at) ~= "string" then return nil end
	local y, mo, d, h, mi, s = at:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then return nil end
	-- UTC -> os.time: compute the local offset once.
	local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
	local offset = os.time() - os.time(os.date("!*t"))
	return t + offset
end

local function fail(msg, pause)
	Sync.busy = false
	Sync.ok = false
	Sync.status = msg
	queue = {}
	if pause then Sync.blockedUntil = os.time() + PAUSE_S end
end

local function handlers()
	local server = launch.agentServer
	return server and server.handlers
end

-- History ------------------------------------------------------------------------------
local function dpsOf(s)
	if (s.FullDPS or 0) > 0 then return s.FullDPS end
	return s.CombinedDPS or s.TotalDPS or 0
end

local function weakest(s)
	local m
	for _, t in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
		local v = s[t .. "MaximumHitTaken"]
		if v and v > 0 and (not m or v < m) then m = v end
	end
	return m or 0
end

local function pctChange(a, b)
	if not a or a <= 0 then return nil end
	local d = (b - a) / a * 100
	if math.abs(d) < 0.01 then return nil end
	return string.format("%s%.1f%%", d >= 0 and "+" or "", d)
end

-- Same one-line summary as agent-mcp's diffSummary.
local function summary(before, after)
	if not before then return "first sync" end
	local parts = {}
	if before.level ~= after.level then table.insert(parts, string.format("level %s->%s", tostring(before.level), tostring(after.level))) end
	local d = pctChange(dpsOf(before.stats or {}), dpsOf(after.stats or {}))
	if d then table.insert(parts, "DPS " .. d) end
	local e = pctChange((before.stats or {}).TotalEHP, (after.stats or {}).TotalEHP or 0)
	if e then table.insert(parts, "EHP " .. e) end
	local bi, ai = {}, {}
	for _, i in ipairs(before.items or {}) do bi[i.slot] = i end
	for _, i in ipairs(after.items or {}) do ai[i.slot] = i end
	local items = 0
	for slot, x in pairs(bi) do local y = ai[slot] if not y or y.name ~= x.name or y.base ~= x.base or y.mods ~= x.mods then items = items + 1 end end
	for slot in pairs(ai) do if not bi[slot] then items = items + 1 end end
	local bg = {}
	for _, g in ipairs(before.gems or {}) do bg[#bg + 1] = g.name .. "/" .. g.level .. "/" .. g.quality end
	local ag = {}
	for _, g in ipairs(after.gems or {}) do ag[g.name .. "/" .. g.level .. "/" .. g.quality] = (ag[g.name .. "/" .. g.level .. "/" .. g.quality] or 0) + 1 end
	local gems = 0
	for _, k in ipairs(bg) do if (ag[k] or 0) > 0 then ag[k] = ag[k] - 1 else gems = gems + 1 end end
	local bn = {}
	for _, id in ipairs(before.nodes or {}) do bn[id] = true end
	local passives = 0
	local an = {}
	for _, id in ipairs(after.nodes or {}) do an[id] = true if not bn[id] then passives = passives + 1 end end
	for id in pairs(bn) do if not an[id] then passives = passives + 1 end end
	if items > 0 or gems > 0 or passives > 0 then
		table.insert(parts, string.format("%d items, %d gems, %d passives changed", items, gems, passives))
	end
	return #parts > 0 and table.concat(parts, ", ") or "no changes"
end

local function isoNow()
	return os.date("!%Y-%m-%dT%H:%M:%S.000Z")
end

local function record(last, char, state, xml)
	local dir = historyDir()
	local base = safe(last.realm or "pc") .. "_" .. safe(last.account) .. "_" .. safe(char.name)
	local file = dir .. base .. ".json"
	local history = readJson(file) or { version = 1, account = last.account, realm = last.realm or "pc", character = char.name, characterHash = common.sha1(char.name), entries = {} }
	history.league = char.league
	history.build = char.name .. " - synced"
	local at = isoNow()
	local entry = {}
	for k, v in pairs(state) do entry[k] = v end
	entry.characterHash = nil
	entry.at = at
	entry.league = char.league
	-- Snapshot of the build, like agent-mcp keeps for compare.
	if xml then
		MakeDir(dir .. base)
		local name = at:gsub("[:.]", "-") .. ".xml"
		local f = io.open(dir .. base .. "/" .. name, "w")
		if f then
			f:write(xml)
			f:close()
			entry.snapshot = name
		end
		local all = {}
		local handle = NewFileSearch(dir .. base .. "/*.xml")
		while handle do
			table.insert(all, handle:GetFileName())
			if not handle:NextFile() then break end
		end
		table.sort(all)
		for i = 1, #all - MAX_SNAPSHOTS do os.remove(dir .. base .. "/" .. all[i]) end
	end
	entry.summary = summary(history.entries[#history.entries], entry)
	table.insert(history.entries, entry)
	while #history.entries > MAX_ENTRIES do table.remove(history.entries, 2) end
	writeJson(file, history)
	-- index.json: the Progress card's timeline.
	local index = readJson(dir .. "index.json") or {}
	index.last = { account = history.account, realm = history.realm, character = history.character }
	index.characters = index.characters or {}
	local timeline = {}
	for _, x in ipairs(history.entries) do
		local s = x.stats or {}
		table.insert(timeline, { at = x.at, level = x.level, dps = math.floor(dpsOf(s) + 0.5), ehp = math.floor((s.TotalEHP or 0) + 0.5),
			life = math.floor((s.Life or 0) + 0.5), es = math.floor((s.EnergyShield or 0) + 0.5), maxHit = math.floor(weakest(s) + 0.5), summary = x.summary })
	end
	index.characters[history.characterHash] = { name = history.character, league = history.league, build = history.build, mainSkill = entry.mainSkill, timeline = timeline }
	writeJson(dir .. "index.json", index)
	return entry.summary
end

-- Sync ---------------------------------------------------------------------------------
function Sync.start(build, auto)
	if Sync.busy then return end
	local ok, last = Sync.check(build)
	if not ok then Sync.status, Sync.ok = last, false return end
	if os.time() < Sync.blockedUntil then
		Sync.status, Sync.ok = string.format("pathofexile.com asked for a pause; try again in %d s.", Sync.blockedUntil - os.time()), false
		return
	end
	if os.time() - Sync.lastAt < MIN_RESYNC_S then
		Sync.status, Sync.ok = "Synced less than a minute ago; try again in a moment.", false
		return
	end
	local h = handlers()
	if not h or not h.character_import then Sync.status, Sync.ok = "The agent link is not running in this window (Options shows why).", false return end
	Sync.busy, Sync.ok = true, nil
	Sync.lastAt = os.time()
	Sync.status = (auto and "Auto-sync: " or "") .. "downloading " .. last.character .. " (3 requests, 2 s apart)..."
	local realm = last.realm or "pc"
	local account = urlencode(last.account)
	local function bad(errMsg, what)
		if tostring(errMsg):find("429") then return fail("pathofexile.com asked for a pause (429); waiting 10 minutes before the next sync.", true) end
		if tostring(errMsg):find("40[13]") then return fail("The profile is private: make the Characters tab public at pathofexile.com > My Account > Privacy Settings.") end
		return fail("Could not download the " .. what .. " (" .. tostring(errMsg) .. ").")
	end
	request(HOST .. "character-window/get-characters?accountName=" .. account .. "&realm=" .. realm, function(body, errMsg)
		if errMsg then return bad(errMsg, "character list") end
		local okList, list = pcall(dkjson.decode, body or "")
		if not okList or type(list) ~= "table" then return fail("pathofexile.com sent an unreadable character list.") end
		local char
		for _, c in ipairs(list) do if type(c) == "table" and tostring(c.name):lower() == last.character:lower() then char = c end end
		if not char then return fail(last.account .. " has no character " .. last.character .. " any more.") end
		local q = "accountName=" .. account .. "&character=" .. urlencode(char.name) .. "&realm=" .. realm
		request(HOST .. "character-window/get-items?" .. q, function(itemsBody, err2)
			if err2 then return bad(err2, "items") end
			local okItems, items = pcall(dkjson.decode, itemsBody or "")
			if not okItems or type(items) ~= "table" then return fail("pathofexile.com sent unreadable items.") end
			request(HOST .. "character-window/get-passive-skills?" .. q, function(passBody, err3)
				if err3 then return bad(err3, "passive tree") end
				local okPass, passives = pcall(dkjson.decode, passBody or "")
				if not okPass or type(passives) ~= "table" then return fail("pathofexile.com sent an unreadable passive tree.") end
				local res = h.character_import({ character = char, items = items, passives = passives, realm = realm,
					name = build.buildName, accountHash = common.sha1(last.account) })
				if not res or not res.ok then return fail(res and res.error or "PoB could not import the character.") end
				if build.dbFileName then pcall(build.SaveDBFile, build) end
				local xml = h.export_build_xml and h.export_build_xml({})
				local okRec, text = pcall(record, last, char, res.state, xml and xml.xml)
				Sync.busy = false
				Sync.ok = okRec
				Sync.status = okRec and ("Synced " .. char.name .. " at " .. os.date("%H:%M") .. ": " .. tostring(text)) or ("Imported, but the history could not be written: " .. tostring(text))
			end)
		end)
	end)
end

return Sync
