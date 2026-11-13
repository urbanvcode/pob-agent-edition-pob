-- Agent Edition: passive trees on demand (Stage 17).
--
-- Release zips leave out Ruthless, "alternate" and older passive tree versions (about 500 MB). Their
-- files are listed in TreeData/packs.json (written by tools/build-release.ps1: size and SHA256 of
-- every file, and the fork commit they come from). When a build needs one of them, PoB downloads
-- just that folder from raw.githubusercontent.com at that commit, checks every file and only then
-- puts it in place (tree.lua last, so a half-finished download never looks installed).
--   * Opening a build in the window: a popup asks first and shows progress (async thread).
--   * Anything else (Tree tab version list, imports, the AI's headless engine): downloads right away.
--   * Offline or blocked: a clear message, nothing half-written is left behind.
-- A git checkout has every tree and no packs.json, so nothing here does anything there.

-- Loaded once (LoadModule runs the file again on every call)
if AgentTreePacksModule then return AgentTreePacksModule end

local json = require("dkjson")

local TreePacks = { }
local packsDoc  -- nil = not read yet, false = no packs.json

local function treeDir()
	local base = GetScriptPath and GetScriptPath() or ""
	if base ~= "" then return base .. "/TreeData/" end
	return "TreeData/"
end

local function fileExists(path)
	local f = io.open(path, "rb")
	if f then f:close() return true end
	return false
end

local function doc()
	if packsDoc == nil then
		packsDoc = false
		local f = io.open(treeDir() .. "packs.json", "rb")
		if f then
			local ok, d = pcall(json.decode, f:read("*a"))
			f:close()
			if ok and type(d) == "table" and type(d.packs) == "table" and type(d.source) == "string" then packsDoc = d end
		end
	end
	return packsDoc or nil
end

function TreePacks.Info(ver)
	local d = doc()
	return d and d.packs[ver] or nil
end

function TreePacks.Installed(ver)
	return fileExists(treeDir() .. ver .. "/tree.lua") or fileExists(treeDir() .. ver .. "/data.json")
end

-- True when the release left this tree out and it has not been downloaded yet.
function TreePacks.Missing(ver)
	return TreePacks.Info(ver) ~= nil and not TreePacks.Installed(ver)
end

function TreePacks.Label(ver)
	return (treeVersions and treeVersions[ver] and treeVersions[ver].display) or tostring(ver):gsub("_", ".")
end

function TreePacks.SizeMb(vers)
	local total = 0
	for _, v in ipairs(vers) do total = total + ((TreePacks.Info(v) or {}).size or 0) end
	return math.max(1, math.floor(total / 1048576 + 0.5))
end

-- Tree versions a build XML uses that still have to be downloaded.
function TreePacks.MissingInXml(xmlText)
	local list, seen = { }, { }
	if type(xmlText) ~= "string" or not doc() then return list end
	for ver in xmlText:gmatch('<Spec[^>]-treeVersion="([%w_]+)"') do
		if not seen[ver] and TreePacks.Missing(ver) then
			seen[ver] = true
			list[#list + 1] = ver
		end
	end
	return list
end

local function filesSpec(info)
	local parts = { }
	for _, f in ipairs(info.files or { }) do
		parts[#parts + 1] = f.path .. "|" .. tostring(f.size) .. "|" .. f.sha256
	end
	return table.concat(parts, "\n")
end

-- Runs in a background thread (LaunchSubScript) or, for the synchronous path, in the main one.
-- Returns true, or nil and a message.
local DOWNLOAD_SCRIPT = [[
local dir, source, ver, spec, userAgent, proxy, progressName = ...
local progressFn = progressName and _G[progressName]
local req = AgentRealRequire or require  -- the headless wrapper hides lcurl from require()
local curl = req("lcurl.safe")
local sha2 = req("sha2")
if not curl then return nil, "no HTTP library (lcurl)" end
local files = { }
for line in spec:gmatch("[^\n]+") do
	local p, s, h = line:match("^(.-)|(%d+)|(%x+)$")
	if p then files[#files + 1] = { path = p, size = tonumber(s), sha256 = h:lower() } end
end
if #files == 0 then return nil, "no file list" end
-- tree.lua last: it is what marks the tree as installed
table.sort(files, function(a, b)
	if (a.path == "tree.lua") ~= (b.path == "tree.lua") then return b.path == "tree.lua" end
	return a.path < b.path
end)
local function cleanup()
	for _, f in ipairs(files) do os.remove(dir .. ver .. "/" .. f.path .. ".part") end
end
for i, f in ipairs(files) do
	if f.path:find("%.%.") or f.path:find("^[/\\]") then cleanup() return nil, "bad file name in packs.json" end
	local chunks = { }
	local easy = curl.easy()
	easy:setopt_url(source .. ver .. "/" .. f.path)
	easy:setopt(curl.OPT_USERAGENT, userAgent)
	easy:setopt(curl.OPT_FOLLOWLOCATION, 1)
	easy:setopt(curl.OPT_CONNECTTIMEOUT, 15)
	easy:setopt(curl.OPT_LOW_SPEED_LIMIT, 1024)
	easy:setopt(curl.OPT_LOW_SPEED_TIME, 30)
	if proxy and proxy ~= "" then easy:setopt(curl.OPT_PROXY, proxy) end
	easy:setopt_writefunction(function(data) chunks[#chunks + 1] = data return true end)
	local _, err = easy:perform()
	local code = easy:getinfo(curl.INFO_RESPONSE_CODE)
	easy:close()
	if err or code ~= 200 then
		cleanup()
		return nil, err and tostring(err:msg()) or ("HTTP " .. tostring(code))
	end
	local body = table.concat(chunks)
	if #body ~= f.size or sha2.sha256(body) ~= f.sha256 then
		cleanup()
		return nil, f.path .. " did not match packs.json (size or SHA256)"
	end
	local out = io.open(dir .. ver .. "/" .. f.path .. ".part", "wb")
	if not out then cleanup() return nil, "cannot write " .. dir .. ver end
	out:write(body)
	out:close()
	if progressFn then progressFn(ver, i, #files) end
end
for _, f in ipairs(files) do
	local final = dir .. ver .. "/" .. f.path
	os.remove(final)
	if not os.rename(final .. ".part", final) then cleanup() return nil, "cannot rename " .. final end
end
return true
]]

local function userAgent()
	return "PoB-Agent-Edition/" .. tostring(launch and launch.versionNumber or "?") .. " (tree pack)"
end

local function prepare(ver)
	local info = TreePacks.Info(ver)
	if not info then return nil, "no tree pack " .. tostring(ver) end
	MakeDir(treeDir() .. ver)
	-- Packs are flat today; create sub folders just in case
	for _, f in ipairs(info.files or { }) do
		local sub = f.path:match("^(.*)/[^/]+$")
		if sub then MakeDir(treeDir() .. ver .. "/" .. sub) end
	end
	return info
end

function TreePacks.OfflineMessage(ver, err)
	return string.format("PoB Agent Edition needs the %s passive tree for this build. It is not part of the\n"
		.. "default download and could not be fetched (%s).\n"
		.. "Connect to the internet and open the build again: it downloads once (%d MB) from GitHub.",
		TreePacks.Label(ver), tostring(err or "offline?"), TreePacks.SizeMb({ ver }))
end

-- Synchronous download (headless engine, Tree tab, imports). Returns true or nil, message.
function TreePacks.Download(ver)
	local info, err = prepare(ver)
	if not info then return nil, err end
	ConPrintf("[Agent] downloading passive tree pack %s (%d MB)...", ver, TreePacks.SizeMb({ ver }))
	local fn = assert(loadstring(DOWNLOAD_SCRIPT))
	local ok, res, msg = pcall(fn, treeDir(), doc().source, ver, filesSpec(info), userAgent(), launch and launch.proxyURL, nil)
	if not ok then return nil, tostring(res) end
	if not res then return nil, msg end
	return true
end

-- Called by PassiveTree before it reads TreeData/<ver>: fetch a missing pack or raise a clear error.
function TreePacks.Ensure(ver)
	if not TreePacks.Missing(ver) then return end
	local ok, err = TreePacks.Download(ver)
	if not ok then
		ConPrintf("[Agent] tree pack %s failed: %s", ver, tostring(err))
		error(TreePacks.OfflineMessage(ver, err), 0)
	end
end

-- Progress from the background thread (LaunchSubScript sub call, looked up in _G)
function AgentTreePackProgress(ver, done, total)
	TreePacks.progress = { ver = ver, done = done, total = total }
end

-- main:SetMode("BUILD", ...) hook for the window: when the build needs trees that are not installed,
-- ask, download them in the background with a progress popup, then open the build. Returns true when
-- it took over (the mode change happens later, or not at all).
function TreePacks.InterceptBuildOpen(args)
	if HEADLESS or not LaunchSubScript or not doc() then return false end
	local dbFileName, buildName, buildXML = args[1], args[2], args[3]
	local xmlText = buildXML
	if not xmlText and dbFileName then
		local f = io.open(dbFileName, "rb")
		if f then xmlText = f:read("*a") f:close() end
	end
	local missing = TreePacks.MissingInXml(xmlText)
	if #missing == 0 then return false end
	local labels = { }
	for _, v in ipairs(missing) do labels[#labels + 1] = TreePacks.Label(v) end
	local what = table.concat(labels, ", ")
	local mb = TreePacks.SizeMb(missing)
	main:OpenConfirmPopup("Passive tree needed",
		string.format("This build uses the %s passive tree, which is not part of the\n"
			.. "default download (Ruthless and older trees are fetched when needed).\n\n"
			.. "Download it now? %d MB from GitHub, checked file by file, kept for next time.", what, mb),
		"Download", function()
			TreePacks.DownloadAsync(missing, function(ok, err, failedVer)
				if ok then
					main:SetMode("BUILD", unpack(args))
				else
					main:OpenMessagePopup("Passive tree not downloaded", TreePacks.OfflineMessage(failedVer, err))
				end
			end)
		end)
	return true
end

-- Background download of several packs one after another, with a progress popup.
function TreePacks.DownloadAsync(vers, onDone)
	local index = 0
	local popup
	local function finish(ok, err, ver)
		TreePacks.progress = nil
		if popup then
			for i, p in ipairs(main.popups) do if p == popup then table.remove(main.popups, i) break end end
		end
		onDone(ok, err, ver)
	end
	local function nextOne()
		index = index + 1
		local ver = vers[index]
		if not ver then return finish(true) end
		local info, err = prepare(ver)
		if not info then return finish(nil, err, ver) end
		TreePacks.progress = { ver = ver, done = 0, total = #(info.files or { }) }
		local id = LaunchSubScript(DOWNLOAD_SCRIPT, "", "AgentTreePackProgress", treeDir(), doc().source, ver, filesSpec(info), userAgent(), launch.proxyURL or "", "AgentTreePackProgress")
		if not id then return finish(nil, "could not start the download", ver) end
		launch:RegisterSubScript(id, function(ok, msg)
			if ok then nextOne() else finish(nil, msg or "download failed", ver) end
		end)
	end
	local controls = { }
	controls.label = new("LabelControl", nil, { 0, 30, 0, 16 }, function()
		local p = TreePacks.progress
		if not p then return "^7Starting..." end
		return string.format("^7Downloading the %s passive tree: file %d of %d", TreePacks.Label(p.ver), p.done, p.total)
	end)
	popup = main:OpenPopup(460, 80, "Downloading passive tree", controls)
	nextOne()
end

AgentTreePacksModule = TreePacks
return TreePacks
