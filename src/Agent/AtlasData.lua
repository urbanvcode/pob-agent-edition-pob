-- Agent Edition: Atlas passive tree data.
-- Reads GGG's official export (github.com/grindinggear/atlastree-export),
-- copied to TreeData/Atlas/<version>/ (data.json + the highest-zoom sprite
-- sheets). Computes node positions, the connection graph and sprite lookups.

local json = require("dkjson")
local m_sin, m_cos, m_rad, m_pi = math.sin, math.cos, math.rad, math.pi

local AtlasData = { latest = "3_30", cache = { } }

-- Newest TreeData/Atlas/<major>_<minor> folder, so updating is just adding a folder
-- (tools/update-atlas.ps1 does that).
do
	local best
	local ok, handle = pcall(NewFileSearch, "TreeData/Atlas/*", true)
	while ok and handle do
		local name = handle:GetFileName()
		local a, b = name:match("^(%d+)_(%d+)$")
		if a then
			local v = tonumber(a) * 1000 + tonumber(b)
			if not best or v > best.v then best = { v = v, name = name } end
		end
		if not handle:NextFile() then break end
	end
	if best then AtlasData.latest = best.name end
end
AtlasData.versions = function()
	local list = { }
	local ok, handle = pcall(NewFileSearch, "TreeData/Atlas/*", true)
	while ok and handle do
		local name = handle:GetFileName()
		if name:match("^%d+_%d+$") then table.insert(list, name) end
		if not handle:NextFile() then break end
	end
	table.sort(list)
	return list
end

local function orbitAngles(n)
	local a = { }
	if n == 16 then
		a = { 0, 30, 45, 60, 90, 120, 135, 150, 180, 210, 225, 240, 270, 300, 315, 330 }
	elseif n == 40 then
		a = { 0, 10, 20, 30, 40, 45, 50, 60, 70, 80, 90, 100, 110, 120, 130, 135, 140, 150, 160, 170, 180, 190, 200, 210, 220, 225, 230, 240, 250, 260, 270, 280, 290, 300, 310, 315, 320, 330, 340, 350 }
	else
		for i = 0, n - 1 do a[i + 1] = 360 * i / n end
	end
	for i, d in ipairs(a) do a[i] = m_rad(d) end
	return a
end

-- GGG markup: "[Thread|Threads]" -> "Threads", "[Maps]" -> "Maps"
local function clean(list)
	local out = { }
	for i, line in ipairs(list or { }) do
		out[i] = line:gsub("%[([^%]|]+)|([^%]]+)%]", "%2"):gsub("%[([^%]]+)%]", "%1")
	end
	return out
end

local function readFile(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

function AtlasData.load(version)
	version = version or AtlasData.latest
	if AtlasData.cache[version] then return AtlasData.cache[version] end
	local dir = "TreeData/Atlas/" .. version .. "/"
	local text = readFile(dir .. "data.json")
	if not text then return nil, "atlas data missing: " .. dir .. "data.json" end
	local raw = json.decode(text)
	if type(raw) ~= "table" or not raw.nodes then return nil, "atlas data unreadable" end

	local atlas = { version = version, dir = dir, nodes = { }, list = { }, groups = raw.groups, points = (raw.points and raw.points.totalPoints) or 150 }
	local radii = raw.constants.orbitRadii
	local perOrbit = raw.constants.skillsPerOrbit
	local angles = { }
	for i, n in ipairs(perOrbit) do angles[i - 1] = orbitAngles(n) end

	for id, n in pairs(raw.nodes) do
		local node = {
			id = id, name = n.name or "", icon = n.icon, stats = clean(n.stats), reminder = clean(n.reminderText),
			group = n.group, orbit = n.orbit or 0, orbitIndex = n.orbitIndex or 0,
			out = n.out or { }, ["in"] = n["in"] or { }, links = { },
		}
		if id == "root" then node.type = "root"
		elseif n.isMastery then node.type = "mastery"
		elseif n.isWormhole then node.type = "wormhole"
		elseif n.isKeystone then node.type = "keystone"
		elseif n.isNotable then node.type = "notable"
		elseif (n.name or "") == "" and (n.icon or "") == "" then node.type = "start"
		else node.type = "normal" end
		local g = raw.groups[tostring(n.group)]
		if g then
			local r = radii[node.orbit + 1] or 0
			local a = angles[node.orbit] and angles[node.orbit][node.orbitIndex + 1] or 0
			node.angle = a
			node.x = g.x + m_sin(a) * r
			node.y = g.y - m_cos(a) * r
		end
		atlas.nodes[id] = node
		table.insert(atlas.list, node)
	end
	-- Undirected connection graph (masteries are decorations, never linked)
	atlas.edges = { }
	for id, node in pairs(atlas.nodes) do
		for _, other in ipairs(node.out) do
			local o = atlas.nodes[tostring(other)]
			if o and node.type ~= "mastery" and o.type ~= "mastery" then
				node.links[o.id] = true
				o.links[id] = true
				if node.type ~= "root" and o.type ~= "root" then
					table.insert(atlas.edges, { a = node, b = o })
				end
			end
		end
	end
	-- The start node sits where root connects
	for oid in pairs(atlas.nodes.root and atlas.nodes.root.links or { }) do atlas.startId = oid end

	-- Sprites: the 0.5 zoom level is the full-resolution sheet we ship
	atlas.sprites = { }
	for key, zooms in pairs(raw.sprites or { }) do
		local best, bestZoom
		for z, v in pairs(zooms) do
			local zn = tonumber(z)
			if zn and (not bestZoom or zn > bestZoom) then best, bestZoom = v, zn end
		end
		if best then
			local file = best.filename:match("([^/]+)%.webp") or best.filename
			atlas.sprites[key] = { file = dir .. file .. ".webp", w = best.w, h = best.h, zoom = bestZoom, coords = best.coords }
		end
	end
	atlas.minX, atlas.minY, atlas.maxX, atlas.maxY = raw.min_x, raw.min_y, raw.max_x, raw.max_y

	-- League mechanic per node: the mastery emblem in its group, else the nearest one
	local masteries = { }
	for _, node in ipairs(atlas.list) do
		if node.type == "mastery" and node.x then table.insert(masteries, node) end
	end
	local byGroup = { }
	for _, m in ipairs(masteries) do byGroup[m.group] = m.name end
	for _, node in ipairs(atlas.list) do
		if node.type ~= "mastery" and node.type ~= "root" and node.type ~= "start" and node.x then
			local name = byGroup[node.group]
			if not name then
				local best
				for _, m in ipairs(masteries) do
					local d = (m.x - node.x) ^ 2 + (m.y - node.y) ^ 2
					if not best or d < best then best, name = d, m.name end
				end
			end
			node.mechanic = name or "General"
		end
	end

	-- Search index
	for _, node in ipairs(atlas.list) do
		node.searchText = (node.name .. " " .. table.concat(node.stats, " ")):lower()
	end
	AtlasData.cache[version] = atlas
	return atlas
end

-- Shortest path (list of node ids, excluding already allocated) from the
-- allocated set to target. nil if unreachable.
function AtlasData.pathTo(atlas, alloc, targetId)
	if alloc[targetId] then return { } end
	local prev, queue, head = { }, { }, 1
	for id in pairs(alloc) do
		prev[id] = false
		table.insert(queue, id)
	end
	while head <= #queue do
		local id = queue[head]; head = head + 1
		if id == targetId then break end
		for nid in pairs(atlas.nodes[id].links) do
			if prev[nid] == nil and atlas.nodes[nid].type ~= "mastery" then
				prev[nid] = id
				table.insert(queue, nid)
			end
		end
	end
	if prev[targetId] == nil then return nil end
	local path, cur = { }, targetId
	while cur and not alloc[cur] do
		table.insert(path, 1, cur)
		cur = prev[cur]
	end
	return path
end

-- Nodes that stay connected to root when `removed` is taken out of alloc.
function AtlasData.connected(atlas, alloc, removed)
	local keep, queue, head = { root = true }, { "root" }, 1
	while head <= #queue do
		local id = queue[head]; head = head + 1
		for nid in pairs(atlas.nodes[id].links) do
			if alloc[nid] and not keep[nid] and nid ~= removed then
				keep[nid] = true
				table.insert(queue, nid)
			end
		end
	end
	return keep
end

-- Summary of an allocation: points per mechanic, notables/keystones and
-- combined stats (identical stat lines with numbers summed).
function AtlasData.summary(atlas, alloc)
	local mech, mechOrder, special, stats, statOrder = { }, { }, { }, { }, { }
	local used = 0
	for id in pairs(alloc) do
		local n = atlas.nodes[id]
		if n and n.mechanic then
			used = used + 1
			local m = mech[n.mechanic]
			if not m then m = { name = n.mechanic, points = 0, notables = { } }; mech[n.mechanic] = m; table.insert(mechOrder, m) end
			m.points = m.points + 1
			if n.type == "notable" or n.type == "keystone" then
				table.insert(m.notables, n)
				table.insert(special, n)
			end
			for _, line in ipairs(n.stats) do
				local nums = { }
				-- Only the first number is summed ("(Tier 14+)" style numbers stay as written)
				local template = line:gsub("%d+%.?%d*", function(num) table.insert(nums, tonumber(num) or 0) return "#" end, 1)
				local s = stats[template]
				if not s then s = { template = template, sums = { }, count = 0 }; stats[template] = s; table.insert(statOrder, s) end
				s.count = s.count + 1
				for i, v in ipairs(nums) do s.sums[i] = (s.sums[i] or 0) + v end
			end
		end
	end
	table.sort(mechOrder, function(a, b) return a.points > b.points or (a.points == b.points and a.name < b.name) end)
	table.sort(special, function(a, b)
		local ka, kb = a.type == "keystone", b.type == "keystone"
		if ka ~= kb then return ka end
		return a.name < b.name
	end)
	local lines = { }
	for _, s in ipairs(statOrder) do
		local i = 0
		local text = s.template:gsub("#", function()
			i = i + 1
			local v = s.sums[i] or 0
			return (v == math.floor(v)) and tostring(math.floor(v)) or string.format("%.1f", v)
		end)
		table.insert(lines, { text = text, count = s.count })
	end
	table.sort(lines, function(a, b) return a.text < b.text end)
	return { used = used, mechanics = mechOrder, special = special, stats = lines }
end

-- Official atlas tree links:
-- https://www.pathofexile.com/fullscreen-atlas-skill-tree/<ver>/<code>
-- code = base64url( version:u32, class:u8, ascendancy:u8, n:u8, n x node:u16, clusters:u8, masteries:u8 )
local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function b64decode(s)
	s = s:gsub("%+", "-"):gsub("/", "_"):gsub("[^%w%-_]", "")
	local bits, out = 0, { }
	local value = 0
	for i = 1, #s do
		local c = b64chars:find(s:sub(i, i), 1, true)
		if not c then break end
		value = value * 64 + (c - 1)
		bits = bits + 6
		if bits >= 8 then
			bits = bits - 8
			local byte = math.floor(value / 2 ^ bits) % 256
			table.insert(out, byte)
			value = value % (2 ^ bits)
		end
	end
	return out
end
local function b64encode(bytes)
	local out, i = { }, 1
	while i <= #bytes do
		local a, b, c = bytes[i], bytes[i + 1], bytes[i + 2]
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		for k = 3, 0, -1 do
			local idx = math.floor(n / 64 ^ k) % 64
			table.insert(out, b64chars:sub(idx + 1, idx + 1))
		end
		if not b then out[#out] = nil; out[#out] = nil
		elseif not c then out[#out] = nil end
		i = i + 3
	end
	return table.concat(out)
end

function AtlasData.decodeLink(link)
	local code = link:match("atlas%-skill%-tree/[^/]+/([%w%-_=]+)") or link:match("atlas%-skill%-tree/([%w%-_=]+)") or link
	local bytes = b64decode(code)
	if #bytes < 7 then return nil, "not an atlas tree link" end
	local n = bytes[7]
	local nodes = { }
	for i = 0, n - 1 do
		local hi, lo = bytes[8 + i * 2], bytes[9 + i * 2]
		if not hi or not lo then break end
		table.insert(nodes, tostring(hi * 256 + lo))
	end
	return nodes
end

function AtlasData.encodeLink(atlas, alloc)
	local ids = { }
	for id in pairs(alloc) do
		local node = atlas.nodes[id]
		if node and node.type ~= "root" and node.type ~= "start" and tonumber(id) then table.insert(ids, tonumber(id)) end
	end
	table.sort(ids)
	local bytes = { 0, 0, 0, 6, 0, 0, #ids }
	for _, id in ipairs(ids) do
		table.insert(bytes, math.floor(id / 256))
		table.insert(bytes, id % 256)
	end
	table.insert(bytes, 0)
	table.insert(bytes, 0)
	local ver = atlas.version:gsub("_", ".") .. ".0"
	return "https://www.pathofexile.com/fullscreen-atlas-skill-tree/" .. ver .. "/" .. b64encode(bytes)
end

return AtlasData
