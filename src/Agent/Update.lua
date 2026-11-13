-- Path of Building - Agent Edition
--
-- Module: Agent Update
-- Version, install type, portable data mode and the daily release check.
--
-- PoB's own updater stays off in Agent Edition (it would replace our fork with
-- official PoB). Instead this module asks GitHub once a day for the newest
-- release of PoB Agent Edition and the Overview shows a banner when one is
-- out. Updating is done by tools/update.ps1, outside PoB.
--
-- State lives in AgentEdition.json under "update" (agent-mcp reads it too,
-- see agent-mcp/src/update.ts; keep the two in sync):
--   check       false = never check (Options switch); default true
--   checkedAt   os.time() of the last successful check
--   latest      newest release version ("0.3.0"), url, notes (release notes)
--   skip        version the player chose to skip
--   snoozeUntil os.time() until which "Later" hides the banner
--   base        { latest, checkedAt }: newest official PoB release (git installs)
-- Nothing is sent except the version request itself.
--
local json = require("dkjson")
local AgentSettings = LoadModule("Agent/Settings")

local Update = { }

Update.REPO = "urbanvcode/pob-agent-edition"
Update.RELEASES_API = "https://api.github.com/repos/" .. Update.REPO .. "/releases?per_page=20"
Update.BASE_API = "https://api.github.com/repos/PathOfBuildingCommunity/PathOfBuilding/releases/latest"
local DAY = 24 * 60 * 60

-- Install root: the folder holding PathOfBuilding, agent-mcp, luajit (src/../..).
function Update.root()
	local script = GetScriptPath and GetScriptPath() or "."
	return (script:gsub("[/\\]+$", "")) .. "/../.."
end

local function exists(path)
	local f = io.open(path, "rb")
	if f then f:close() return true end
	return false
end

local function readLine(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local text = f:read("*l")
	f:close()
	return text and text:match("^%s*(.-)%s*$") or nil
end

-- Our version from the VERSION file at the root ("0.2.0"), or nil.
function Update.version()
	if Update.cachedVersion == nil then
		local v = readLine(Update.root() .. "/VERSION")
		Update.cachedVersion = (v and v:match("^%d+%.%d+%.%d+")) and v or false
	end
	return Update.cachedVersion or nil
end

-- "git" (clone with .git), "portable" (bundled node\node.exe) or "zip" (installer zip).
function Update.installType()
	local root = Update.root()
	if exists(root .. "/.git/HEAD") or exists(root .. "/.git") then return "git" end
	if exists(root .. "/node/node.exe") then return "portable" end
	return "zip"
end

-- Portable data mode: an empty portable.txt in the root keeps builds and
-- settings in <root>/UserData instead of Documents/Path of Building.
-- agent-mcp reads the same switch (src/paths.ts).
function Update.portableUserPath()
	local root = Update.root()
	if exists(root .. "/portable.txt") then
		return root .. "/UserData/"
	end
end

-- Semantic version compare: -1, 0 or 1. Pre-release suffixes sort before the release.
local function parse(v)
	v = tostring(v or ""):gsub("^v", "")
	local a, b, c, pre = v:match("^(%d+)%.(%d+)%.(%d+)(.*)$")
	if not a then return nil end
	return { tonumber(a), tonumber(b), tonumber(c), pre ~= "" and pre or nil }
end

function Update.compare(x, y)
	local a, b = parse(x), parse(y)
	if not a or not b then return 0 end
	for i = 1, 3 do
		if a[i] ~= b[i] then return a[i] < b[i] and -1 or 1 end
	end
	if a[4] == b[4] then return 0 end
	if not a[4] then return 1 end
	if not b[4] then return -1 end
	return a[4] < b[4] and -1 or 1
end

-- Newest release in a GitHub /releases list (pre-releases included: every 0.x
-- release is one, and /releases/latest skips them). Drafts are ignored.
function Update.pickLatest(list)
	local best
	for _, rel in ipairs(type(list) == "table" and list or { }) do
		local tag = type(rel) == "table" and rel.tag_name
		if tag and not rel.draft and parse(tag) and (not best or Update.compare(tag, best.tag_name) > 0) then
			best = rel
		end
	end
	if not best then return nil end
	return {
		version = tostring(best.tag_name):gsub("^v", ""),
		url = best.html_url,
		notes = tostring(best.body or ""):sub(1, 6000),
		publishedAt = best.published_at,
	}
end

-- Release notes are Markdown; PoB draws plain text.
function Update.plainNotes(md)
	local text = tostring(md or "")
	text = text:gsub("\r", "")
	text = text:gsub("%[([^%]]+)%]%([^%)]+%)", "%1")
	text = text:gsub("%*%*", ""):gsub("`", "")
	text = text:gsub("\n#+%s*", "\n"):gsub("^#+%s*", "")
	text = text:gsub("\n%s*[-*]%s+", "\n- ")
	-- PoB's font has no fancy dashes or ellipsis
	text = text:gsub("\226\128\148", "-"):gsub("\226\128\147", "-"):gsub("\226\128\166", "...")
	text = text:gsub("\226\128\153", "'"):gsub("\226\128\156", '"'):gsub("\226\128\157", '"')
	return text
end

function Update.state(userPath)
	local s = AgentSettings.get(userPath, "update")
	return type(s) == "table" and s or { }
end

local function saveState(userPath, s)
	AgentSettings.set(userPath, "update", s)
end

function Update.enabled(userPath)
	return Update.state(userPath).check ~= false
end

function Update.setEnabled(userPath, on)
	local s = Update.state(userPath)
	s.check = on and true or false
	saveState(userPath, s)
end

-- The release to show in the banner, or nil (none newer, skipped or snoozed).
function Update.available(userPath)
	local s = Update.state(userPath)
	local current = Update.version()
	if s.check == false or not current or not s.latest then return nil end
	if Update.compare(s.latest, current) <= 0 then return nil end
	if s.skip == s.latest then return nil end
	if (tonumber(s.snoozeUntil) or 0) > os.time() then return nil end
	return { version = s.latest, url = s.url, notes = s.notes, current = current }
end

function Update.later(userPath)
	local s = Update.state(userPath)
	s.snoozeUntil = os.time() + DAY
	saveState(userPath, s)
end

function Update.skip(userPath, version)
	local s = Update.state(userPath)
	s.skip = version
	saveState(userPath, s)
end

-- Official PoB is newer than our base: a reminder for developers (git installs).
function Update.baseNewer(userPath)
	local base = Update.state(userPath).base
	local ours = launch and launch.versionNumber
	if type(base) ~= "table" or not base.latest or not ours or ours == "?" then return nil end
	if Update.compare(base.latest, ours) > 0 then return base.latest end
end

-- Daily check (force = ignore the 24 h cache). Asynchronous; done is called
-- with (ok, errMsg) when the answer is in.
function Update.check(userPath, force, done)
	done = done or function() end
	if not launch or not launch.DownloadPage or not userPath or userPath == "" then return done(false, "no user folder") end
	if not Update.version() then return done(false, "no VERSION file") end
	local s = Update.state(userPath)
	if s.check == false and not force then return done(false, "checking is off") end
	if not force and os.time() - (tonumber(s.checkedAt) or 0) < DAY then return done(true) end
	local header = "Accept: application/vnd.github+json\nX-GitHub-Api-Version: 2022-11-28"
	launch:DownloadPage(Update.RELEASES_API, function(response, errMsg)
		if errMsg then return done(false, errMsg) end
		local ok, list = pcall(json.decode, response.body or "")
		local latest = ok and Update.pickLatest(list)
		if not latest then return done(false, "unexpected answer from GitHub") end
		local st = Update.state(userPath)
		st.checkedAt = os.time()
		st.latest, st.url, st.notes = latest.version, latest.url, latest.notes
		saveState(userPath, st)
		if Update.installType() ~= "git" then return done(true) end
		-- Developer reminder: newer official PoB than our base
		launch:DownloadPage(Update.BASE_API, function(resp2, err2)
			if not err2 then
				local ok2, rel = pcall(json.decode, resp2.body or "")
				if ok2 and type(rel) == "table" and rel.tag_name then
					local st2 = Update.state(userPath)
					st2.base = { latest = tostring(rel.tag_name):gsub("^v", ""), checkedAt = os.time() }
					saveState(userPath, st2)
				end
			end
			done(true)
		end, { header = header })
	end, { header = header })
end

-- Starts tools/update.ps1 in its own window. It waits for PoB to close,
-- updates (verifying the SHA256), keeps a backup and restarts PoB.
function Update.startUpdater(extraArgs)
	local root = Update.root():gsub("/", "\\")
	local script = root .. "\\tools\\update.ps1"
	if not exists(script) then return false, "tools\\update.ps1 is missing" end
	local ps = (os.getenv("SystemRoot") or "C:\\Windows") .. "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
	SpawnProcess(ps, string.format('-NoProfile -ExecutionPolicy Bypass -File "%s" -Restart %s', script, extraArgs or ""))
	return true
end

return Update
