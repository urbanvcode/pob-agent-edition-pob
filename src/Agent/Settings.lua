-- Agent Edition settings, kept in <user folder>/AgentEdition.json so the
-- regular PoB (which shares Settings.xml) never drops them.
-- agent-mcp reads the same file (POESESSID for trade searches, the player
-- profile for every AI client). Keep the profile schema in sync with
-- agent-mcp/src/profile.ts.

local json = require("dkjson")

local AgentSettings = { }

local function path(userPath)
	return (userPath or "") .. "AgentEdition.json"
end

function AgentSettings.load(userPath)
	if not userPath or userPath == "" then return { } end
	local f = io.open(path(userPath), "r")
	if not f then return { } end
	local text = f:read("*a")
	f:close()
	local ok, data = pcall(json.decode, text)
	return (ok and type(data) == "table") and data or { }
end

local function save(userPath, data)
	if not userPath or userPath == "" then return false end
	local f = io.open(path(userPath), "w")
	if not f then return false end
	f:write(json.encode(data, { indent = true }))
	f:close()
	return true
end

function AgentSettings.get(userPath, key)
	return AgentSettings.load(userPath)[key]
end

function AgentSettings.set(userPath, key, value)
	if not userPath or userPath == "" then return false end
	local data = AgentSettings.load(userPath)
	if value == "" then value = nil end
	data[key] = value
	return save(userPath, data)
end

-- Player profile -------------------------------------------------------------
-- Stored under "profile". Every AI client reads it first (the profile tool) and
-- adapts: trade vs SSF advice, league, budget, goals and explanation depth.

AgentSettings.PLAY_MODES = {
	{ value = "trade", label = "Trade", desc = "Buy upgrades on the trade site (instant buyout only)." },
	{ value = "ssf", label = "SSF", desc = "Solo Self-Found: no trading. Advice is crafting, farming and drop targets." },
	{ value = "mixed", label = "Mixed", desc = "Show trade and self-found options side by side, labelled." },
}
AgentSettings.EXPLANATION_MODES = {
	{ value = "teach", label = "Teach", desc = "Explain each PoE1 mechanic the first time it matters, compared with PoE2. Not repeated once learned." },
	{ value = "concise", label = "Concise", desc = "Actions and numbers only, one line of why." },
	{ value = "deep", label = "Deep dive", desc = "Full mechanics and maths (more vs increased, DPS formula, EHP layers)." },
}
AgentSettings.EXPERIENCE = {
	{ value = "poe2", label = "Knows PoE2, new to PoE1" },
	{ value = "new", label = "New to Path of Exile" },
	{ value = "poe1", label = "Experienced PoE1 player" },
}

local function valid(list, value)
	for _, entry in ipairs(list) do
		if entry.value == value then return true end
	end
	return false
end

function AgentSettings.label(list, value)
	for _, entry in ipairs(list) do
		if entry.value == value then return entry.label end
	end
	return tostring(value)
end

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function stringList(list)
	local result, seen = { }, { }
	if type(list) ~= "table" then return result end
	for _, v in ipairs(list) do
		local s = trim(v)
		if s ~= "" and not seen[s:lower()] then
			seen[s:lower()] = true
			table.insert(result, s)
		end
	end
	return result
end

local function amount(v)
	v = tonumber(v)
	if not v or v < 0 then return 0 end
	return math.floor(v + 0.5)
end

-- Build preferences from the "Create a build" interview (Stage 11). Keep in sync
-- with agent-mcp/src/profile.ts (PREFERENCE_CHOICES / normalizePreferences).
AgentSettings.PREFERENCE_CHOICES = {
	content = { "clear", "bossing", "both" },
	defence = { "tanky", "balanced", "glass" },
	buttons = { "few", "some", "many" },
	pace = { "big_hits", "fast_hits", "any" },
	novelty = { "proven", "new", "any" },
	start = { "league_start", "mid_league" },
}
AgentSettings.PLAYSTYLES = { "melee", "ranged", "spells", "minions", "totems", "traps", "mines", "dot", "hits" }

local function oneOfList(list, value)
	for _, v in ipairs(list) do
		if v == value then return value end
	end
	return ""
end

function AgentSettings.normalizePreferences(p)
	p = type(p) == "table" and p or { }
	local out = { playstyle = { }, exclude = stringList(p.exclude), likes = stringList(p.likes) }
	for _, v in ipairs(stringList(p.playstyle)) do
		if oneOfList(AgentSettings.PLAYSTYLES, v:lower()) ~= "" then table.insert(out.playstyle, v:lower()) end
	end
	for key, list in pairs(AgentSettings.PREFERENCE_CHOICES) do
		out[key] = oneOfList(list, p[key])
	end
	local hours = tonumber(p.hours)
	out.hours = (hours and hours > 0) and math.floor(hours + 0.5) or 0
	out.budget = trim(p.budget)
	out.updated = type(p.updated) == "string" and p.updated or nil
	return out
end

-- Complete profile with defaults filled in (never nil fields).
function AgentSettings.normalizeProfile(p)
	p = type(p) == "table" and p or { }
	local cur = type(p.currency) == "table" and p.currency or { }
	return {
		playMode = valid(AgentSettings.PLAY_MODES, p.playMode) and p.playMode or "trade",
		hardcore = p.hardcore == true,
		league = trim(p.league),
		currency = {
			chaos = amount(cur.chaos),
			divine = amount(cur.divine),
			other = trim(cur.other),
			updated = type(cur.updated) == "string" and cur.updated or nil,
		},
		goals = stringList(p.goals),
		experience = valid(AgentSettings.EXPERIENCE, p.experience) and p.experience or "poe2",
		explanationMode = valid(AgentSettings.EXPLANATION_MODES, p.explanationMode) and p.explanationMode or "teach",
		learnedTopics = stringList(p.learnedTopics),
		preferences = AgentSettings.normalizePreferences(p.preferences),
		updated = type(p.updated) == "string" and p.updated or nil,
	}
end

function AgentSettings.getProfile(userPath)
	return AgentSettings.normalizeProfile(AgentSettings.load(userPath).profile)
end

-- Merge the given fields into the stored profile (re-read first, so topics
-- the AI marked as learned meanwhile are kept). Returns the new profile.
function AgentSettings.setProfile(userPath, fields)
	local data = AgentSettings.load(userPath)
	local profile = AgentSettings.normalizeProfile(data.profile)
	local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
	for k, v in pairs(fields or { }) do
		if k == "currency" and type(v) == "table" then
			local changed = false
			for ck, cv in pairs(v) do
				if profile.currency[ck] ~= cv then changed = true end
				profile.currency[ck] = cv
			end
			if changed then profile.currency.updated = now end
		else
			profile[k] = v
		end
	end
	profile.updated = now
	profile = AgentSettings.normalizeProfile(profile)
	data.profile = profile
	save(userPath, data)
	return profile
end

-- Goals are edited as one comma/semicolon separated line in the Options popup.
function AgentSettings.parseList(text)
	local list = { }
	for part in tostring(text or ""):gmatch("[^,;]+") do
		table.insert(list, part)
	end
	return stringList(list)
end

return AgentSettings
