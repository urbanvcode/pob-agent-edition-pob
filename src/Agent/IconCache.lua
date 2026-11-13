-- Agent Edition: item icons for the inventory view.
--
-- Icons are GGG's own item art from their public image server
-- (web.poecdn.com). poe.ninja's public item lists map item names and base
-- types to those image links. Everything is downloaded in background
-- threads, written to <user folder>/AgentCache/icons/ and re-used from disk,
-- so each picture is fetched only once:
--   * the name -> icon index: 5 small requests to poe.ninja, refreshed every 14 days
--   * each picture: one request to web.poecdn.com the first time an item is shown
-- No account, session cookie or game data is involved.

local json = require("dkjson")

local IconCache = {
	maxConcurrent = 2,
	refreshDays = 14,
	index = nil,          -- { uniques = { [name] = url }, bases = { [baseName] = url }, updated = time }
	indexState = "idle",  -- idle | loading | ready | failed
	handles = { },        -- [url] = image handle
	files = { },          -- [url] = "pending" | "ready" | "failed"
	queue = { },
	running = 0,
}

local NINJA_TYPES = { "UniqueWeapon", "UniqueArmour", "UniqueAccessory", "UniqueFlask", "BaseType" }
local NINJA_URL = "https://poe.ninja/poe1/api/economy/stash/current/item/overview?league=Standard&type="

local function cacheDir()
	if not main or not main.userPath or main.userPath == "" then return nil end
	return main.userPath .. "AgentCache/icons/"
end

local function enabled()
	return not HEADLESS and launch and launch.agentEdition and LaunchSubScript and cacheDir() ~= nil
end

local function fileExists(path)
	local f = io.open(path, "rb")
	if f then f:close() return true end
	return false
end

-- Background thread: download every list, reduce to { uniques, bases } and write the index file.
local INDEX_SCRIPT = [[
local outPath, baseUrl, typesCsv, userAgent = ...
local curl = require("lcurl.safe")
local json = require("dkjson")
local index = { uniques = { }, bases = { }, updated = os.time() }
for t in typesCsv:gmatch("[^,]+") do
	local chunks = { }
	local easy = curl.easy()
	easy:setopt_url(baseUrl .. t)
	easy:setopt(curl.OPT_USERAGENT, userAgent)
	easy:setopt(curl.OPT_ACCEPT_ENCODING, "")
	easy:setopt(curl.OPT_FOLLOWLOCATION, 1)
	easy:setopt_writefunction(function(data) chunks[#chunks + 1] = data return true end)
	local _, err = easy:perform()
	local code = easy:getinfo(curl.INFO_RESPONSE_CODE)
	easy:close()
	if err or code ~= 200 then
		return false, "poe.ninja " .. t .. ": " .. (err and err:msg() or ("HTTP " .. tostring(code)))
	end
	local data = json.decode(table.concat(chunks))
	for _, line in ipairs(data and data.lines or { }) do
		if line.icon and line.icon:match("^https://web%.poecdn%.com/") then
			if t == "BaseType" then
				local name = line.baseType or line.name
				-- Prefer the plain (non-influenced) variant
				if name and (not index.bases[name] or not line.variant) then index.bases[name] = line.icon end
			elseif line.name and not index.uniques[line.name] then
				index.uniques[line.name] = line.icon
			end
		end
	end
end
local f = io.open(outPath, "w")
if not f then return false, "cannot write " .. outPath end
f:write(json.encode(index))
f:close()
return true
]]

-- Background thread: download one picture straight to disk (binary safe).
local IMAGE_SCRIPT = [[
local url, outPath, userAgent = ...
local curl = require("lcurl.safe")
local tmp = outPath .. ".part"
local f = io.open(tmp, "wb")
if not f then return false, "cannot write " .. tmp end
local easy = curl.easy()
easy:setopt_url(url)
easy:setopt(curl.OPT_USERAGENT, userAgent)
easy:setopt(curl.OPT_FOLLOWLOCATION, 1)
easy:setopt_writefunction(function(data) f:write(data) return true end)
local _, err = easy:perform()
local code = easy:getinfo(curl.INFO_RESPONSE_CODE)
easy:close()
f:close()
if err or code ~= 200 then
	os.remove(tmp)
	return false, err and err:msg() or ("HTTP " .. tostring(code))
end
os.remove(outPath)
os.rename(tmp, outPath)
return true
]]

local function userAgent()
	return "PoB-Agent-Edition/" .. tostring(launch.versionNumber or "?")
end

function IconCache:LoadIndex()
	if self.indexState == "loading" or not enabled() then return end
	local dir = cacheDir()
	MakeDir(main.userPath .. "AgentCache/")
	MakeDir(dir)
	local path = dir .. "index.json"
	local f = io.open(path, "r")
	if f then
		local ok, data = pcall(json.decode, f:read("*a"))
		f:close()
		if ok and type(data) == "table" and data.uniques and data.bases then
			self.index = data
			self.indexState = "ready"
			if os.time() - (tonumber(data.updated) or 0) < self.refreshDays * 86400 then return end
		end
	end
	-- Missing or stale: rebuild in the background (keep using the old one meanwhile).
	self.indexState = self.index and "ready" or "loading"
	self.indexRefreshing = true
	local id = LaunchSubScript(INDEX_SCRIPT, "", "", path, NINJA_URL, table.concat(NINJA_TYPES, ","), userAgent())
	if not id then
		self.indexRefreshing = false
		if not self.index then self.indexState = "failed" end
		return
	end
	launch:RegisterSubScript(id, function(ok, err)
		self.indexRefreshing = false
		if not ok then
			ConPrintf("[Agent] icon index download failed: %s", tostring(err))
			if not self.index then self.indexState = "failed"; self.indexError = err end
			return
		end
		local f2 = io.open(path, "r")
		if f2 then
			local ok2, data = pcall(json.decode, f2:read("*a"))
			f2:close()
			if ok2 and type(data) == "table" then
				self.index = data
				self.indexState = "ready"
			end
		end
	end)
end

-- Icon URL for a PoB item, or nil.
function IconCache:UrlFor(item)
	if not self.index then return nil end
	if item.rarity == "UNIQUE" or item.rarity == "RELIC" then
		local url = item.title and self.index.uniques[item.title]
		if url then return url end
	end
	return item.baseName and self.index.bases[item.baseName] or nil
end

local function fileNameFor(url)
	-- .../gen/image/<data>/<hash>/<Name>.png -> <hash>_<Name>.png
	local hash, name = url:match("/([%w]+)/([%w_%-]+%.png)$")
	if hash then return hash .. "_" .. name end
	return (url:gsub("[^%w%.]", "_")):sub(-80)
end

function IconCache:Pump()
	while self.running < self.maxConcurrent and #self.queue > 0 do
		local job = table.remove(self.queue, 1)
		local id = LaunchSubScript(IMAGE_SCRIPT, "", "", job.url, job.path, userAgent())
		if not id then
			self.files[job.url] = "failed"
		else
			self.running = self.running + 1
			launch:RegisterSubScript(id, function(ok)
				self.running = self.running - 1
				self.files[job.url] = ok and "ready" or "failed"
				self:Pump()
			end)
		end
	end
end

-- Image handle for an item (loaded from disk; queued for download if new), or nil.
function IconCache:Get(item)
	if not item or not enabled() then return nil end
	if not self.index then
		if self.indexState == "idle" then self:LoadIndex() end
		return nil
	end
	local url = self:UrlFor(item)
	if not url then return nil end
	local handle = self.handles[url]
	if handle then return handle end
	local path = cacheDir() .. fileNameFor(url)
	local state = self.files[url]
	if state == nil then
		if fileExists(path) then
			state = "ready"
		else
			state = "pending"
			table.insert(self.queue, { url = url, path = path })
			self:Pump()
		end
		self.files[url] = state
	end
	if state == "ready" then
		handle = NewImageHandle()
		handle:Load(path, "ASYNC", "MIPMAP")
		self.handles[url] = handle
		return handle
	end
	return nil
end

function IconCache:Status()
	if not enabled() then return "off" end
	if self.indexState == "loading" then return "loading" end
	if self.indexState == "failed" then return "failed" end
	if self.running > 0 or #self.queue > 0 then return "downloading" end
	return "ready"
end

return IconCache
