-- Agent Edition: passive tree differences as a respec plan.
--
-- Shared by the Tree tab (labels and the changes panel, Classes/TreeTab.lua) and the
-- agent handlers (Agent/Handlers/TreePlan.lua). Pure data: nothing here calculates
-- or changes the build. Built on PoB Community's own compare overlay (PassiveTreeView
-- compareSpec colours): the same nodes are "new", "removed", "mastery changed" and
-- "jewel changed" here.
--
-- A change is one row of the plan: a node and the path that leads to it. Notables,
-- keystones, masteries, jewel sockets and dead ends are rows; small passives on the
-- way belong to the first row whose path takes them (`own`). A new row's `path` holds every
-- new node it needs, so ticked new rows always connect; a removed row takes out its `own`
-- nodes, and whatever was reached only through them is cut off (PoB drops it, we report it).
local dkjson = require("dkjson")
local t_insert, t_sort = table.insert, table.sort
local m_max = math.max

local TreeDiff = { }

local function isStart(node)
	return node.type == "ClassStart" or node.type == "AscendClassStart"
end

local IMPORTANT = { Notable = true, Keystone = true, Mastery = true, Socket = true }

local function nodeName(node)
	return node and (node.dn or node.name) or "?"
end

local function effectText(spec, effectId)
	local effect = effectId and spec.tree.masteryEffects and spec.tree.masteryEffects[effectId]
	if not effect then return effectId and ("effect " .. tostring(effectId)) or "none" end
	return table.concat(effect.sd or { }, " / ")
end
TreeDiff.effectText = effectText

local function jewelOf(spec, build, nodeId)
	local itemId = spec.jewels and spec.jewels[nodeId]
	local item = itemId and itemId > 0 and build and build.itemsTab and build.itemsTab.items[itemId]
	return item or nil, itemId
end

local function jewelName(item)
	if not item then return "empty" end
	return item.title or item.name or item.baseName or "jewel"
end

-- Rows for one side: `set` = the differing nodes (ids), `spec` = the spec that has them,
-- `anchor(id)` = true for nodes both trees keep (where paths start).
local function branches(set, spec, anchor)
	local parent, depth, queue, reached = { }, { }, { }, { }
	local function linked(id)
		local node = spec.nodes[id]
		return node and node.linked or { }
	end
	for id in pairs(set) do
		for _, other in ipairs(linked(id)) do
			if anchor(other.id) then
				if not reached[id] then reached[id] = true depth[id] = 1 t_insert(queue, id) end
				break
			end
		end
	end
	local function run()
		local i = 1
		while queue[i] do
			local id = queue[i]
			i = i + 1
			for _, other in ipairs(linked(id)) do
				local oid = other.id
				if set[oid] and not reached[oid] then
					reached[oid] = true
					parent[oid] = id
					depth[oid] = depth[id] + 1
					t_insert(queue, oid)
				end
			end
		end
	end
	run()
	-- Masteries have no links: they hang on a differing node of their own group, if any.
	for id in pairs(set) do
		local node = spec.nodes[id]
		if not reached[id] and node and node.type == "Mastery" then
			local best
			for oid in pairs(set) do
				local o = spec.nodes[oid]
				if oid ~= id and reached[oid] and o and o.group == node.group then
					if not best or (o.type == "Notable" and spec.nodes[best].type ~= "Notable") then best = oid end
				end
			end
			reached[id] = true
			if best then parent[id], depth[id] = best, depth[best] + 1 else depth[id] = 1 end
		end
	end
	-- Anything left (a cut-off island, cluster nodes) starts its own paths.
	for id in pairs(set) do
		if not reached[id] then reached[id] = true depth[id] = 1 queue = { id } run() end
	end
	local hasChild = { }
	for id, p in pairs(parent) do hasChild[p] = true end
	local ends = { }
	for id in pairs(set) do
		local node = spec.nodes[id]
		if (node and IMPORTANT[node.type]) or (node and node.ascendancyName and node.isNotable) or not hasChild[id] then
			t_insert(ends, id)
		end
	end
	t_sort(ends, function(a, b) if depth[a] ~= depth[b] then return depth[a] < depth[b] end return a < b end)
	local claimed, rows = { }, { }
	for _, id in ipairs(ends) do
		local path, own, cur = { }, { }, id
		while cur do
			t_insert(path, 1, cur)
			cur = parent[cur]
		end
		for _, pid in ipairs(path) do
			if not claimed[pid] then claimed[pid] = true t_insert(own, pid) end
		end
		t_insert(rows, { node = id, path = path, own = own })
	end
	return rows
end

-- The differences between `base` (the player's tree, PoB's primary spec) and `other`.
-- baseBuild / otherBuild own the specs' jewels (the same build for two specs of one build).
-- Returns { changes = {...}, sameBuild, note? } or nil, error.
function TreeDiff.diff(base, other, baseBuild, otherBuild)
	if not base or not other then return nil, "no tree to compare" end
	local sameBuild = otherBuild == nil or otherBuild == baseBuild
	otherBuild = otherBuild or baseBuild
	local res = { changes = { }, sameBuild = sameBuild }
	-- Another class or ascendancy: the node differences are still listed, but a respec cannot
	-- change the class, and another ascendancy is a new Labyrinth run, not Orbs of Regret.
	local otherAsc = base.curAscendClassId ~= other.curAscendClassId
	if base.curClassId ~= other.curClassId then
		res.classDiffers = true
		res.note = string.format("THE CLASS DIFFERS (%s and %s): these are the node differences only; a respec cannot change the class, so gains are not simulated", tostring(base.curClassName), tostring(other.curClassName))
	elseif otherAsc then
		res.ascendancyDiffers = true
		res.note = string.format("the ascendancy differs (%s and %s): the other ascendancy's nodes are listed but not simulated (that needs a new Labyrinth run, not Orbs of Regret)", tostring(base.curAscendClassName), tostring(other.curAscendClassName))
	end
	local function counted(node)
		return node and not isStart(node)
	end
	local added, removed = { }, { }
	for id, node in pairs(other.allocNodes) do
		if not base.allocNodes[id] and counted(node) then added[id] = true end
	end
	for id, node in pairs(base.allocNodes) do
		if not other.allocNodes[id] and counted(node) then removed[id] = true end
	end
	local function row(kind, r, spec)
		local node = spec.nodes[r.node]
		local ch = { kind = kind, id = (kind == "add" and "+" or "-") .. r.node, node = r.node, name = nodeName(node), type = node and node.type,
			path = r.path, own = r.own, ascendancy = node and node.ascendancyName and true or nil,
			cluster = (r.node >= 65536 or (node and node.expansionJewel and true)) or nil }
		-- Nodes of another class or ascendancy cannot be taken by a respec: listed, not simulated.
		if res.classDiffers or (otherAsc and node and node.ascendancyName) then ch.notSimulated = true end
		local points = 0
		for _, id in ipairs(r.own) do
			local n = spec.nodes[id]
			if n and not n.ascendancyName then points = points + 1 end
		end
		ch.points = kind == "add" and points or -points
		if node and node.type == "Mastery" then
			ch.effect = (kind == "add" and other or base).masterySelections[r.node]
			ch.effectText = effectText(spec, ch.effect)
		end
		if node and node.type == "Socket" then
			local item = jewelOf(kind == "add" and other or base, kind == "add" and otherBuild or baseBuild, r.node)
			ch.jewel = item and jewelName(item) or nil
		end
		t_insert(res.changes, ch)
	end
	for _, r in ipairs(branches(added, other, function(id) return other.allocNodes[id] and not added[id] end)) do row("add", r, other) end
	for _, r in ipairs(branches(removed, base, function(id) return base.allocNodes[id] and not removed[id] end)) do row("remove", r, base) end
	-- Kept in both: mastery effect or jewel changed.
	for id, node in pairs(base.allocNodes) do
		if other.allocNodes[id] and counted(node) then
			if node.type == "Mastery" then
				local a, b = base.masterySelections[id], other.masterySelections[id]
				if a ~= b then
					t_insert(res.changes, { kind = "mastery", id = "m" .. id, node = id, name = nodeName(node), type = "Mastery", path = { id }, own = { id }, points = 0,
						oldEffect = a, newEffect = b, oldText = effectText(base, a), newText = effectText(other, b) })
				end
			elseif node.type == "Socket" then
				local a, aId = jewelOf(base, baseBuild, id)
				local b, bId = jewelOf(other, otherBuild, id)
				local same
				if sameBuild then same = (aId or 0) == (bId or 0)
				else same = (a and a:BuildRaw()) == (b and b:BuildRaw()) end
				if not same then
					t_insert(res.changes, { kind = "jewel", id = "j" .. id, node = id, name = nodeName(node), type = "Socket", path = { id }, own = { id }, points = 0,
						oldJewel = jewelName(a), newJewel = jewelName(b), simulated = sameBuild or nil,
						cluster = (node.expansionJewel or (a and a.clusterJewel) or (b and b.clusterJewel)) and true or nil })
				end
			end
		end
	end
	-- Stable order: adds, removes, masteries, jewels; within a kind the bigger rows first.
	local ORDER = { add = 1, remove = 2, mastery = 3, jewel = 4 }
	local index = { }
	for i, ch in ipairs(res.changes) do index[ch] = i end
	t_sort(res.changes, function(a, b)
		if ORDER[a.kind] ~= ORDER[b.kind] then return ORDER[a.kind] < ORDER[b.kind] end
		return index[a] < index[b]
	end)
	return res
end

-- Label tag for a changed node, as the Tree tab draws it.
function TreeDiff.tag(ch)
	local tag
	if ch.kind == "add" then tag = "NEW"
	elseif ch.kind == "remove" then tag = "REMOVED"
	elseif ch.kind == "mastery" then tag = "MASTERY CHANGED"
	else tag = ch.cluster and "CLUSTER JEWEL CHANGED" or "JEWEL CHANGED" end
	if ch.cluster and ch.kind ~= "jewel" then tag = tag .. " (cluster)" end
	if ch.order then tag = ch.order .. ". " .. tag end
	return tag
end

-- The order to take the changes in: best gain per Orb of Regret or point first, but never
-- before what it needs. A new node comes after the new rows on its path; a removal comes
-- after the removals further out that pass through it (a node is refunded only from the edge).
-- score(ch) = the change's own gain (higher is better); sets ch.order = 1, 2, 3...
function TreeDiff.order(changes, score)
	local needs = { }
	local endOf = { }
	for _, ch in ipairs(changes) do endOf[ch.node] = endOf[ch.node] or ch end
	for _, ch in ipairs(changes) do
		needs[ch] = { }
		if ch.kind == "add" then
			for _, id in ipairs(ch.path) do
				local other = endOf[id]
				if other and other ~= ch and other.kind == "add" then needs[ch][other] = true end
			end
		end
	end
	for _, outer in ipairs(changes) do
		if outer.kind == "remove" then
			for _, id in ipairs(outer.path) do
				local inner = endOf[id]
				if inner and inner ~= outer and inner.kind == "remove" then needs[inner][outer] = true end
			end
		end
	end
	local placed, n = { }, 0
	while n < #changes do
		local best, bestScore
		for _, ch in ipairs(changes) do
			if not placed[ch] then
				local ready = true
				for dep in pairs(needs[ch]) do if not placed[dep] then ready = false break end end
				if ready then
					local cost = m_max(1, math.abs(ch.points or 0))
					local v = (score(ch) or 0) / cost
					if not bestScore or v > bestScore + 1e-9 then best, bestScore = ch, v end
				end
			end
		end
		if not best then -- a cycle cannot happen, but never loop forever
			for _, ch in ipairs(changes) do if not placed[ch] then best = ch break end end
		end
		n = n + 1
		placed[best] = true
		best.order = n
		best.needs = { }
		for dep in pairs(needs[best]) do t_insert(best.needs, dep.id) end
		t_sort(best.needs)
	end
end

-- Gain colour of a change: damage gain (green), defence gain (blue), loss (red) or none,
-- with a strength from 0.35 (small) to 1 (10% or more) for shading.
function TreeDiff.tone(g)
	if not g then return nil end
	local dps, ehp, hit = g.dpsPct or 0, g.ehpPct or 0, g.hitPct or 0
	local worst = math.min(dps, ehp, hit)
	local function strength(v) return 0.35 + 0.65 * math.min(1, math.abs(v) / 10) end
	if worst < -0.05 and dps + ehp + hit < 0 then return { kind = "loss", strength = strength(worst) } end
	local def = m_max(ehp, hit)
	if dps > 0.05 and dps >= def then return { kind = "damage", strength = strength(dps) } end
	if def > 0.05 then return { kind = "defence", strength = strength(def) } end
	return { kind = "none", strength = 0 }
end

-- Per node: which change it belongs to, and whether it is that change's end node.
function TreeDiff.nodeIndex(changes)
	local byNode = { }
	for _, ch in ipairs(changes or { }) do
		for _, id in ipairs(ch.own) do
			if not byNode[id] then byNode[id] = { change = ch, isEnd = id == ch.node } end
		end
		if byNode[ch.node] then byNode[ch.node].isEnd = true end
	end
	return byNode
end

-- The tree with the ticked changes applied: an undo state PoB can import
-- (PassiveSpec:RestoreUndoState), plus the jewels (same build only).
-- skip = { [change id] = true } for unticked rows.
function TreeDiff.state(base, other, changes, skip, sameBuild)
	skip = skip or { }
	local alloc, masteries, jewels, overrides = { }, { }, { }, { }
	for id in pairs(base.allocNodes) do alloc[id] = true end
	for id, e in pairs(base.masterySelections) do masteries[id] = e end
	for id, item in pairs(base.jewels or { }) do jewels[id] = item end
	for id, o in pairs(base.hashOverrides or { }) do overrides[id] = o end
	for _, ch in ipairs(changes) do
		if not skip[ch.id] then
			if ch.kind == "add" then
				for _, id in ipairs(ch.path) do
					alloc[id] = true
					if other.masterySelections[id] then masteries[id] = other.masterySelections[id] end
					if other.hashOverrides and other.hashOverrides[id] then overrides[id] = other.hashOverrides[id] end
					if sameBuild and other.jewels and other.jewels[id] then jewels[id] = other.jewels[id] end
				end
			elseif ch.kind == "remove" then
				-- Its own nodes only: nodes further out that need them lose their path, and
				-- PoB leaves them out (reported as cut off), so a shallow removal shows its full cost.
				for _, id in ipairs(ch.own) do alloc[id] = nil masteries[id] = nil end
			elseif ch.kind == "mastery" then
				masteries[ch.node] = ch.newEffect
			elseif ch.kind == "jewel" and sameBuild then
				jewels[ch.node] = other.jewels[ch.node] or 0
			end
		end
	end
	local hashList = { }
	for id in pairs(alloc) do t_insert(hashList, id) end
	t_sort(hashList)
	return {
		classId = base.curClassId, ascendClassId = base.curAscendClassId, secondaryAscendClassId = base.curSecondaryAscendClassId,
		hashList = hashList, hashOverrides = overrides, masteryEffects = masteries, treeVersion = base.treeVersion,
	}, jewels, alloc
end

-- Respec cost of going from `base` to `result` (a spec with the plan applied).
-- Orbs of Regret: one per refunded passive point (poewiki, Orb of Regret: "one passive
-- skill refund point"); a mastery is a point like any other node (PoB counts it so).
-- Ascendancy refunds and mastery effect swaps are counted, not priced.
function TreeDiff.cost(base, result)
	local c = { regrets = 0, ascRefunded = 0, masterySwaps = 0, added = 0, removed = 0 }
	for id, node in pairs(base.allocNodes) do
		if not isStart(node) and not result.allocNodes[id] then
			if node.ascendancyName then c.ascRefunded = c.ascRefunded + 1
			else c.regrets = c.regrets + 1 end
		end
	end
	for id, node in pairs(result.allocNodes) do
		if not isStart(node) and not base.allocNodes[id] and not node.ascendancyName then c.added = c.added + 1 end
		if node.type == "Mastery" and base.allocNodes[id] and base.masterySelections[id] ~= result.masterySelections[id] then
			c.masterySwaps = c.masterySwaps + 1
		end
	end
	c.removed = c.regrets
	return c
end

-- Notes the AI left on a spec's nodes (edit { op: "spec_notes" }), kept in the build file.
function TreeDiff.note(specs, nodeId)
	for _, spec in ipairs(specs) do
		local n = spec and spec.agentNotes and spec.agentNotes[nodeId]
		if n and n ~= "" then return n end
	end
end

-- Files ------------------------------------------------------------------------------
local function readFile(path)
	local f = path and io.open(path, "rb")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return text
end
TreeDiff.readFile = readFile

-- The previous character sync of this build's character (agent-mcp's character tool keeps
-- one XML per sync next to <historyDir>/<character>.json). The build is matched by PoB's
-- lastCharacterHash (as the Overview's Progress card does), else by the synced build name.
-- When the open build is the synced build, its newest snapshot is the build itself, so the
-- one before is used. Returns xml, title or nil, error.
function TreeDiff.lastSync(historyDir, buildName, characterHash)
	if not historyDir then return nil, "no history folder" end
	historyDir = historyDir:gsub("\\", "/"):gsub("/?$", "/")
	local index = readFile(historyDir .. "index.json")
	local ok, data = pcall(dkjson.decode, index or "")
	local chars = ok and type(data) == "table" and data.characters or { }
	local hash = characterHash
	if not (hash and chars[hash]) then
		hash = nil
		for h, c in pairs(chars) do
			if type(c) == "table" and c.build == buildName then hash = h end
		end
	end
	if not hash then
		return nil, "no character sync matches this build (sync the character first: ask the AI to sync it, or use character { account, character })"
	end
	-- Find its history file.
	local hist, histFile
	local handle = NewFileSearch(historyDir .. "*.json")
	while handle do
		local file = handle:GetFileName()
		if file ~= "index.json" then
			local okH, h = pcall(dkjson.decode, readFile(historyDir .. file) or "")
			if okH and type(h) == "table" and h.characterHash == hash then hist, histFile = h, file break end
		end
		if not handle:NextFile() then break end
	end
	if not hist or type(hist.entries) ~= "table" then return nil, "the sync history of this character is missing" end
	local dir = historyDir .. histFile:gsub("%.json$", "") .. "/"
	local snaps = { }
	for i = #hist.entries, 1, -1 do
		local e = hist.entries[i]
		if type(e) == "table" and type(e.snapshot) == "string" and readFile(dir .. e.snapshot) then t_insert(snaps, e) end
	end
	if #snaps == 0 then return nil, "no saved sync snapshot for " .. tostring(hist.character) end
	local pick = snaps[1]
	if hist.build == buildName and snaps[2] then pick = snaps[2] end
	local when = tostring(pick.at or ""):gsub("T", " "):sub(1, 16)
	return readFile(dir .. pick.snapshot), "Last sync " .. when
end

-- Build files in the Builds folder (top level and sub folders), for "Other build...".
function TreeDiff.buildFiles(root)
	local list = { }
	local function scan(dir, prefix, depth)
		local handle = NewFileSearch(dir .. "*.xml")
		while handle do
			local file = handle:GetFileName()
			t_insert(list, { name = prefix .. file:gsub("%.xml$", ""), file = dir .. file, mtime = handle:GetFileModifiedTime() })
			if not handle:NextFile() then break end
		end
		if depth > 0 then
			local dirs = NewFileSearch(dir .. "*", true)
			while dirs do
				local sub = dirs:GetFileName()
				if sub ~= "." and sub ~= ".." then scan(dir .. sub .. "/", prefix .. sub .. "/", depth - 1) end
				if not dirs:NextFile() then break end
			end
		end
	end
	if root then scan(root:gsub("\\", "/"):gsub("/?$", "/"), "", 1) end
	t_sort(list, function(a, b) return (a.mtime or 0) > (b.mtime or 0) end)
	return list
end

return TreeDiff
