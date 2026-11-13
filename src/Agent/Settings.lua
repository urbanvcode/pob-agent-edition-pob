-- Agent Edition settings, kept in <user folder>/AgentEdition.json so the
-- regular PoB (which shares Settings.xml) never drops them.
-- pob-mcp reads the same file (e.g. POESESSID for trade searches).

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

function AgentSettings.get(userPath, key)
	return AgentSettings.load(userPath)[key]
end

function AgentSettings.set(userPath, key, value)
	if not userPath or userPath == "" then return false end
	local data = AgentSettings.load(userPath)
	if value == "" then value = nil end
	data[key] = value
	local f = io.open(path(userPath), "w")
	if not f then return false end
	f:write(json.encode(data, { indent = true }))
	f:close()
	return true
end

return AgentSettings
