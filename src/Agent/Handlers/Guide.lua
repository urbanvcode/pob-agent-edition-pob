-- Agent Edition guide mode (Stage 3): stages of a guide build, the guide's data
-- per stage, and the gap between the open build and a guide stage.
-- Loaded by Core.lua with (handlers, Ops). Every number comes from PoB: each
-- gap is simulated in the player's build and the build is put back exactly.
local handlers, Ops = ...

local t_insert, t_sort = table.insert, table.sort
local priorities, rankPlan, detectStage -- defined further down
local m_min, m_max, m_abs = math.min, math.max, math.abs

local function num(v)
	if type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge then return v end
	return nil
end

local function strip(text)
	return (tostring(text or ''):gsub('%^x%x%x%x%x%x%x', ''):gsub('%^%d', ''))
end

local function recalc()
	build.buildFlag = true
	return Ops.get_main_output()
end

local function dpsOf(s)
	if not s then return 0 end
	if (s.FullDPS or 0) > 0 then return s.FullDPS end
	return s.CombinedDPS or s.TotalDPS or 0
end

local function stats()
	return handlers.key_stats({}).stats
end

-- Character level where maps start (end of the campaign); below it the character is levelling.
local MAPS_LEVEL = 68

-- Gear slots a guide stage is compared on (jewels are added per socket).
local GEAR = { 'Weapon 1', 'Weapon 2', 'Helmet', 'Body Armour', 'Gloves', 'Boots', 'Amulet', 'Ring 1', 'Ring 2', 'Belt',
	'Flask 1', 'Flask 2', 'Flask 3', 'Flask 4', 'Flask 5' }

-- Stages --------------------------------------------------------------------------
-- A stage is a tree spec plus the item, skill and config set of the same title,
-- the way PoB's own Loadouts menu pairs them (exact title or a {link} id).
local function cleanTitle(title)
	local t = tostring(title or 'Default'):gsub('%s*%{[%w,]+%}%s*', ' '):gsub('^%s+', ''):gsub('%s+$', '')
	return t ~= '' and t or 'Default'
end

local function matchSet(orderList, sets, title)
	if not orderList or #orderList == 0 then return nil end
	if #orderList == 1 then return orderList[1] end
	for _, id in ipairs(orderList) do
		if (sets[id].title or 'Default') == title then return id end
	end
	local links = title:match('%{([%w,]+)%}')
	if links then
		for linkId in links:gmatch('[^,]+') do
			for _, id in ipairs(orderList) do
				local l = (sets[id].title or ''):match('%{([%w,]+)%}')
				if l and (',' .. l .. ','):find(',' .. linkId .. ',', 1, true) then return id end
			end
		end
	end
	local plain = cleanTitle(title):lower()
	for _, id in ipairs(orderList) do
		if cleanTitle(sets[id].title):lower() == plain then return id end
	end
	return nil
end

local function stageList()
	local list = {}
	local items, skills, config = build.itemsTab, build.skillsTab, build.configTab
	for i, spec in ipairs(build.treeTab.specList) do
		local title = spec.title or 'Default'
		t_insert(list, {
			index = i, title = cleanTitle(title),
			itemSet = matchSet(items.itemSetOrderList, items.itemSets, title),
			skillSet = matchSet(skills.skillSetOrderList, skills.skillSets, title),
			configSet = config.configSetOrderList and matchSet(config.configSetOrderList, config.configSets, title) or nil,
		})
	end
	return list
end

local function activateStage(stage)
	if build.treeTab.activeSpec ~= stage.index then build.treeTab:SetActiveSpec(stage.index) end
	if stage.itemSet and build.itemsTab.activeItemSetId ~= stage.itemSet then build.itemsTab:SetActiveItemSet(stage.itemSet) end
	if stage.skillSet and build.skillsTab.activeSkillSetId ~= stage.skillSet then build.skillsTab:SetActiveSkillSet(stage.skillSet) end
	if stage.configSet and build.configTab.SetActiveConfigSet and build.configTab.activeConfigSetId ~= stage.configSet then
		build.configTab:SetActiveConfigSet(stage.configSet)
	end
	recalc()
end

local function countedNode(node)
	return node and node.type ~= 'ClassStart' and node.type ~= 'AscendClassStart'
end

-- Levelling stages: a title such as "Act 1-3", "Level 30", "Leveling", or a small tree.
local LEVELLING_WORDS = { 'act', 'acts', 'lvl', 'level', 'levels', 'leveling', 'levelling', 'campaign' }
local LEVELLING_POINTS = 70
local function levellingTitle(title)
	local t = ' ' .. (tostring(title or ''):lower():gsub('[^%w]+', ' ')) .. ' '
	for _, w in ipairs(LEVELLING_WORDS) do
		if t:find(' ' .. w .. ' ', 1, true) then return true end
	end
	return t:find(' lvl?%d') ~= nil
end

-- Character level a gem needs at gem level 1 (nil when PoB does not know the gem).
local function gemReq(name)
	local key = tostring(name or ''):lower()
	local id = data.gemForBaseName[key] or data.gemForBaseName[key .. ' support']
	local gem = id and data.gems[id]
	local levels = gem and gem.grantedEffect and gem.grantedEffect.levels
	return levels and levels[1] and levels[1].levelRequirement or nil
end

-- Light data of one stage, read without switching to it (for stage detection).
local function lightStage(stage)
	local spec = build.treeTab.specList[stage.index]
	local nodes, points = {}, 0
	for id, node in pairs(spec.allocNodes or {}) do
		if countedNode(node) then
			t_insert(nodes, id)
			if not node.ascendancyName then points = points + 1 end
		end
	end
	t_sort(nodes)
	local itemNames = {}
	local set = stage.itemSet and build.itemsTab.itemSets[stage.itemSet]
	for _, slot in ipairs(GEAR) do
		local entry = set and set[slot]
		local item = entry and entry.selItemId and build.itemsTab.items[entry.selItemId]
		if item then itemNames[slot] = strip(item.name) end
	end
	local gems, skills = {}, {}
	local skillSet = stage.skillSet and build.skillsTab.skillSets[stage.skillSet]
	for _, g in ipairs(skillSet and skillSet.socketGroupList or {}) do
		if g.enabled ~= false then
			for _, gem in ipairs(g.gemList or {}) do
				if gem.enabled ~= false and gem.nameSpec and gem.nameSpec ~= '' then
					t_insert(gems, gem.nameSpec)
					local effect = gem.gemData and gem.gemData.grantedEffect
					if effect and not effect.support then t_insert(skills, { name = gem.nameSpec, req = gemReq(gem.nameSpec) }) end
				end
			end
		end
	end
	return { index = stage.index, title = stage.title, points = points, nodes = nodes, items = itemNames, gems = gems,
		skills = skills, levelling = levellingTitle(stage.title) or points < LEVELLING_POINTS }
end

local function pointsAtLevel()
	local o = build.calcsTab.mainOutput or {}
	local level = tonumber(build.characterLevel) or 1
	return m_min(level - 1, 99) + 23 + (o.ExtraPoints or 0)
end

-- params: { all = bool } -> stages with light data (all of them, or only the open one)
handlers.guide_stages = function(params)
	local list = stageList()
	local out = {}
	for _, stage in ipairs(list) do
		if params.all or stage.index == build.treeTab.activeSpec then t_insert(out, lightStage(stage)) end
	end
	local spec = build.spec
	return { ok = true, stages = out, active = build.treeTab.activeSpec, name = build.buildName,
		level = tonumber(build.characterLevel), className = spec.curClassName, ascendancy = spec.curAscendClassName,
		pointsAtLevel = pointsAtLevel() }
end

-- Full data of one stage -----------------------------------------------------------
local function skillGroups()
	local out = {}
	local skills = Ops.get_skills()
	for _, g in ipairs(skills and skills.groups or {}) do
		local gems, active = {}, nil
		for _, gem in ipairs(g.gems or {}) do
			if gem.name and gem.name ~= '' then
				t_insert(gems, { index = gem.index, name = gem.name, level = gem.level, quality = gem.quality, support = gem.isSupport == true, enabled = gem.enabled ~= false })
				if not gem.isSupport and gem.enabled ~= false and not active then active = gem.name end
			end
		end
		if #gems > 0 then
			t_insert(out, { index = g.index, label = g.label ~= '' and g.label or nil, slot = g.slot, enabled = g.enabled ~= false,
				main = g.index == (skills.mainSocketGroup or build.mainSocketGroup), skill = active, gems = gems })
		end
	end
	return out
end

local function explicitMods(item)
	local mods = {}
	for _, list in ipairs({ item.implicitModLines, item.explicitModLines }) do
		for _, line in ipairs(list or {}) do
			if line.line and #mods < 8 then t_insert(mods, strip(line.line)) end
		end
	end
	return mods
end

local function gearItems()
	local out = {}
	local spec = build.spec
	for _, it in ipairs(Ops.get_items() or {}) do
		local slot = it.slot
		local socket = tonumber(slot:match('^Jewel (%d+)$'))
		local wanted = socket and spec.allocNodes[socket] and socket < 65536
		if not wanted then for _, s in ipairs(GEAR) do if s == slot then wanted = true end end end
		if wanted and it.id and it.id > 0 then
			local item = build.itemsTab.items[it.id]
			if item then
				t_insert(out, { slot = slot, name = strip(item.name), base = item.baseName, rarity = item.rarity,
					raw = item:BuildRaw(), mods = explicitMods(item), active = it.active })
			end
		end
	end
	return out
end

local function configInput()
	local out = {}
	for k, v in pairs(build.configTab.input or {}) do
		if type(v) == 'boolean' or type(v) == 'number' or type(v) == 'string' then out[k] = v end
	end
	return out
end

-- params: { stage = spec index } -> everything guide_gap needs about that stage
handlers.guide_data = function(params)
	local list = stageList()
	local stage = list[tonumber(params.stage) or build.treeTab.activeSpec]
	if not stage then return { ok = false, error = 'no stage ' .. tostring(params.stage) .. ' (guide has ' .. #list .. ')' } end
	activateStage(stage)
	local spec = build.spec
	local nodes, masteries, points, ascPoints = {}, {}, 0, 0
	for id, node in pairs(spec.allocNodes) do
		if countedNode(node) then
			t_insert(nodes, id)
			if node.ascendancyName then ascPoints = ascPoints + 1 else points = points + 1 end
			if node.type == 'Mastery' and spec.masterySelections[id] then masteries[tostring(id)] = spec.masterySelections[id] end
		end
	end
	t_sort(nodes)
	local notesTab = build.notesTab
	local notes = notesTab and (notesTab.controls and notesTab.controls.edit and notesTab.controls.edit.buf or notesTab.lastContent) or build.notesText or ''
	if type(notes) ~= 'string' then notes = '' end
	return { ok = true, index = stage.index, title = stage.title, stages = #list,
		className = spec.curClassName, ascendancy = spec.curAscendClassName, level = tonumber(build.characterLevel),
		nodes = nodes, masteries = masteries, points = points, ascPoints = ascPoints,
		groups = skillGroups(), items = gearItems(), config = configInput(), stats = stats(),
		mainSkill = handlers.key_stats({}).mainSkill, notes = strip(notes) }
end

-- Gap: the open build against a guide stage ---------------------------------------
local function gain(before, after)
	local d0, d1 = dpsOf(before), dpsOf(after)
	local e0, e1 = before.TotalEHP or 0, after.TotalEHP or 0
	return {
		dps = d1 - d0, dpsPct = d0 > 0 and (d1 - d0) / d0 * 100 or 0,
		ehp = e1 - e0, ehpPct = e0 > 0 and (e1 - e0) / e0 * 100 or 0,
		life = (after.Life or 0) - (before.Life or 0),
		res = {
			fire = (after.FireResist or 0) - (before.FireResist or 0), cold = (after.ColdResist or 0) - (before.ColdResist or 0),
			lightning = (after.LightningResist or 0) - (before.LightningResist or 0), chaos = (after.ChaosResist or 0) - (before.ChaosResist or 0),
		},
	}
end

-- One what_if (applies ops, measures, rolls back): the gain of a set of ops.
local function sim(ops)
	if #ops == 0 then return nil end
	local res = handlers.what_if({ ops = ops })
	if not res.ok then return { error = res.error } end
	local g = gain(res.before, res.after)
	local failed = {}
	for _, r in ipairs(res.results or {}) do if not r.ok then t_insert(failed, r.error) end end
	if #failed > 0 then g.failed = failed end
	if res.rolledBack == false then g.rollbackProblem = res.rollbackProblem end
	return g
end

-- Jewels in sockets: PoB's item undo state does not put socketed jewels back in
-- a safe order, so a jewel is tried by hand and removed again.
local function jewelSim(slotName, raw)
	local itemsTab = build.itemsTab
	local slot = itemsTab.slots[slotName]
	if not slot then return { error = 'no slot ' .. slotName } end
	local oldId = slot.selItemId or 0
	local flags = { build.modFlag, itemsTab.modFlag, build.spec.modFlag }
	local before = stats()
	local res, err = Ops.add_item_text({ text = raw, slotName = slotName, noAutoEquip = true })
	if not res then return { error = err } end
	recalc()
	local g = gain(before, stats())
	slot:SetSelItemId(oldId)
	local item = itemsTab.items[res.id]
	if item then itemsTab:DeleteItem(item, true) end
	itemsTab:PopulateSlots()
	recalc()
	build.modFlag, itemsTab.modFlag, build.spec.modFlag = flags[1], flags[2], flags[3]
	return g
end

local function lower(s) return tostring(s or ''):lower() end

-- A name matches when it is the whole name or the part before a comma ("Rat's Nest, Ursine Pelt").
local function skipped(skip, ...)
	for i = 1, select('#', ...) do
		local v = select(i, ...)
		if v and (skip[lower(v)] or skip[lower(tostring(v):match('^([^,]+)') or ''):gsub('%s+$', '')]) then return true end
	end
	return false
end

local function nodeName(node) return node.dn or node.name or tostring(node.id) end

-- Tree: missing nodes ordered into a path (nearest notable first), each step
-- simulated on top of the previous ones (that is how they would be taken).
local function treeGap(guide, skip, simulate, maxSteps, levelling)
	local spec = build.spec
	local nodes = spec.nodes
	local out = { steps = {}, masteries = {}, extra = {}, extraPoints = 0, missingPoints = 0, notFound = 0, otherAscendancy = 0, have = 0, total = 0 }
	if guide.className and guide.className ~= spec.curClassName then
		out.classMismatch = guide.className
		return out
	end
	local want, missing = {}, {}
	for _, id in ipairs(guide.nodes or {}) do want[id] = true end
	for id in pairs(want) do
		local node = nodes[id]
		if not node then
			out.notFound = out.notFound + 1
		elseif countedNode(node) then
			out.total = out.total + 1
			if spec.allocNodes[id] then
				out.have = out.have + 1
			elseif node.ascendancyName and node.ascendancyName ~= spec.curAscendClassName then
				out.otherAscendancy = out.otherAscendancy + 1
			elseif node.type ~= 'Mastery' then
				missing[id] = node
				if not node.ascendancyName then out.missingPoints = out.missingPoints + 1 end
			end
		end
	end
	for id, node in pairs(spec.allocNodes) do
		if countedNode(node) and not want[id] and id < 65536 then
			if not skipped(skip, nodeName(node)) then
				t_insert(out.extra, { id = id, name = nodeName(node), type = node.type, ascendancy = node.ascendancyName })
				if not node.ascendancyName then out.extraPoints = out.extraPoints + 1 end
			end
		end
	end
	t_sort(out.extra, function(a, b) return a.id < b.id end)

	-- Breadth-first from the allocated tree through missing nodes only.
	local parent, order, seen = {}, {}, {}
	local queue = {}
	for id, node in pairs(spec.allocNodes) do
		if node.type ~= 'Mastery' then t_insert(queue, node) seen[id] = true end
	end
	t_sort(queue, function(a, b) return a.id < b.id end)
	local head = 1
	while head <= #queue do
		local node = queue[head]
		head = head + 1
		for _, other in ipairs(node.linked or {}) do
			if missing[other.id] and not seen[other.id] then
				seen[other.id] = true
				parent[other.id] = node.id
				t_insert(queue, other)
				t_insert(order, other.id)
			end
		end
	end
	local children = {}
	for id, p in pairs(parent) do children[p] = (children[p] or 0) + 1 end
	local targets = {}
	for _, id in ipairs(order) do
		local node = missing[id]
		if node.type ~= 'Normal' or not children[id] then t_insert(targets, id) end
	end
	out.unreachable = 0
	for id in pairs(missing) do if not seen[id] then out.unreachable = out.unreachable + 1 end end

	-- Masteries: a different choice, or one the player has not taken.
	local pendingMasteries = {}
	for idText, effectId in pairs(guide.masteries or {}) do
		local id = tonumber(idText)
		local node = nodes[id]
		if node and node.type == 'Mastery' then
			local effect = spec.tree.masteryEffects[effectId]
			local text = effect and table.concat(effect.sd or {}, ' / ') or ('effect ' .. tostring(effectId))
			local current = spec.allocNodes[id] and spec.masterySelections[id]
			if current ~= effectId and not skipped(skip, nodeName(node), text) then
				local entry = { id = id, effect = effectId, name = nodeName(node), text = strip(text), group = node.group,
					swap = current and true or false }
				if current then
					local ce = spec.tree.masteryEffects[current]
					entry.current = ce and strip(table.concat(ce.sd or {}, ' / ')) or nil
				end
				t_insert(pendingMasteries, entry)
			end
		end
	end
	t_sort(pendingMasteries, function(a, b) return a.id < b.id end)

	-- Greedy: the target with the fewest points left to reach it goes next.
	local taken = {}
	for id in pairs(spec.allocNodes) do taken[id] = true end
	local plan, nodeStep = {}, {}
	local remaining = targets
	while #remaining > 0 do
		local best, bestChain
		for _, id in ipairs(remaining) do
			if not taken[id] then
				local chain, cur = {}, id
				while cur and not taken[cur] do t_insert(chain, 1, cur) cur = parent[cur] end
				local node = missing[id]
				local better = not best or #chain < #bestChain
					or (#chain == #bestChain and node.type ~= 'Normal' and missing[best].type == 'Normal')
				if better then best, bestChain = id, chain end
			end
		end
		if not best then break end
		for _, id in ipairs(bestChain) do taken[id] = true end
		local target = missing[best]
		local names = {}
		for _, id in ipairs(bestChain) do
			local n = missing[id]
			if n.type ~= 'Normal' then t_insert(names, nodeName(n)) end
		end
		if #names == 0 then names = { nodeName(target) .. (#bestChain > 1 and (' (+' .. (#bestChain - 1) .. ' small)') or '') } end
		local after = nodeStep[parent[bestChain[1]]]
		for _, id in ipairs(bestChain) do nodeStep[id] = #plan + 1 end
		if not skipped(skip, nodeName(target)) then
			t_insert(plan, { after = after, kind = target.ascendancyName and 'ascendancy' or (target.type == 'Keystone' and 'keystone' or (target.type == 'Socket' and 'jewel socket' or (target.type == 'Notable' and 'notable' or 'passives'))),
				target = nodeName(target), names = names, nodes = bestChain, points = #bestChain, ascendancy = target.ascendancyName ~= nil })
		end
		-- Masteries whose cluster is now reachable follow right after.
		for i = #pendingMasteries, 1, -1 do
			local m = pendingMasteries[i]
			local reach = m.swap
			if not reach then
				for id in pairs(taken) do
					local n = nodes[id]
					if n and n.group == m.group and n.type ~= 'Mastery' then reach = true break end
				end
			end
			if reach then
				t_insert(plan, { kind = m.swap and 'mastery swap' or 'mastery', target = m.name, names = { m.name .. ': ' .. m.text }, mastery = m, points = m.swap and 0 or 1, current = m.current })
				table.remove(pendingMasteries, i)
			end
		end
		local left = {}
		for _, id in ipairs(remaining) do if not taken[id] then t_insert(left, id) end end
		remaining = left
	end
	for _, m in ipairs(pendingMasteries) do
		t_insert(plan, { kind = 'mastery', target = m.name, names = { m.name .. ': ' .. m.text }, mastery = m, points = 1, unreachable = true })
	end

	-- Simulate the path step by step on a copy of the tree, then put it back.
	-- Levelling: the guide's next tree takes over, so extra passives are no respec.
	if levelling then out.respecIgnored = true end
	local limit = maxSteps or 40
	local extraIds = {}
	for _, e in ipairs(out.extra) do extraIds[e.id] = true end
	if simulate and #plan > 0 then
		local undo = spec:CreateUndoState()
		local flags = { build.modFlag, spec.modFlag, build.treeTab.modFlag }
		local before = stats()
		local first = before
		local ok, err = pcall(function()
			for i, step in ipairs(plan) do
				if i > limit then break end
				if step.mastery then
					local m = step.mastery
					local node = nodes[m.id]
					local effect = spec.tree.masteryEffects[m.effect]
					local clash = false
					for otherId, otherEffect in pairs(spec.masterySelections) do
						if otherEffect == m.effect and otherId ~= m.id and spec.allocNodes[otherId] then
							-- The effect sits on one of the player's extra masteries: it moves.
							if extraIds[otherId] then
								spec:DeallocNode(nodes[otherId])
								step.moves = nodeName(nodes[otherId])
							else
								clash = true
							end
						end
					end
					if effect and not clash and (node.alloc or node.path) then
						node.sd = effect.sd
						node.allMasteryOptions = false
						spec.tree:ProcessStats(node)
						spec.masterySelections[m.id] = m.effect
						if not node.alloc then spec:AllocNode(node) end
					else
						step.skippedSim = clash and 'effect already taken on another mastery' or 'cluster not reached'
					end
				else
					for _, id in ipairs(step.nodes) do
						local node = nodes[id]
						if node and not node.alloc and node.path then spec:AllocNode(node) end
					end
				end
				recalc()
				local now = stats()
				step.gain = gain(before, now)
				before = now
			end
			if #out.extra > 0 and not levelling then
				for _, e in ipairs(out.extra) do
					local node = nodes[e.id]
					if node and node.alloc then spec:DeallocNode(node) end
				end
				recalc()
				local now = stats()
				out.removeExtra = gain(before, now)
				before = now
			end
			out.all = gain(first, before)
		end)
		spec:RestoreUndoState(undo)
		recalc()
		build.modFlag, spec.modFlag, build.treeTab.modFlag = flags[1], flags[2], flags[3]
		if not ok then out.simError = tostring(err) end
	end
	out.steps = plan
	return out
end

-- Gems: guide skill groups matched to the player's by their active skill.
local function gemGap(guide, skip, simulate, level)
	local mine = skillGroups()
	local out = { steps = {}, have = 0, total = 0, groups = {} }
	local used = {}
	local function find(gg)
		for _, g in ipairs(mine) do
			if not used[g.index] and g.skill and gg.skill and lower(g.skill) == lower(gg.skill) then return g end
		end
		for _, g in ipairs(mine) do
			if not used[g.index] and gg.slot and g.slot == gg.slot and not g.skill and not gg.skill then return g end
		end
	end
	for _, gg in ipairs(guide.groups or {}) do
		if gg.enabled then
			local g = find(gg)
			if g then used[g.index] = true end
			local wanted = {}
			for _, gem in ipairs(gg.gems) do if gem.enabled then t_insert(wanted, gem) end end
			out.total = out.total + #wanted
			local entry = { skill = gg.skill or gg.label or ('group in ' .. tostring(gg.slot)), slot = gg.slot, main = gg.main, group = g and g.index or nil,
				guideCount = #wanted, playerCount = 0, missing = {}, wrong = {}, levels = {} }
			if g then
				local have = {}
				for _, gem in ipairs(g.gems) do
					if gem.enabled then have[lower(gem.name)] = gem entry.playerCount = entry.playerCount + 1 end
				end
				local guideNames = {}
				for _, gem in ipairs(wanted) do
					guideNames[lower(gem.name)] = true
					local p = have[lower(gem.name)]
					if p then
						out.have = out.have + 1
						if (gem.level or 0) > (p.level or 0) or (gem.quality or 0) > (p.quality or 0) + 4 then
							t_insert(entry.levels, { name = gem.name, from = p.level, to = gem.level, qFrom = p.quality, qTo = gem.quality })
						end
					elseif not skipped(skip, gem.name) then
						t_insert(entry.missing, gem)
					else
						out.have = out.have + 1
					end
				end
				for _, gem in ipairs(g.gems) do
					if gem.enabled and gem.support and not guideNames[lower(gem.name)] and not skipped(skip, gem.name) then
						t_insert(entry.wrong, { name = gem.name, index = gem.index })
					end
				end
			elseif skipped(skip, gg.skill, gg.label) then
				out.have = out.have + #wanted
				entry = nil
			end
			if entry then
				entry.absent = g == nil
				if g == nil then entry.gems = wanted end
				t_insert(out.groups, entry)
				-- Gems the character is too low for come later (levelling).
				for _, gem in ipairs(entry.missing) do
					local req = gemReq(gem.name)
					if req and req > level then gem.later = req end
				end
				if g == nil then
					for _, gem in ipairs(wanted) do
						local req = gemReq(gem.name)
						if req and req > level and (not entry.later or req > entry.later) then entry.later = req end
					end
				end
				if simulate then
					if g == nil and entry.later then
						-- not usable yet: no simulation
					elseif g == nil then
						local gems = {}
						for _, gem in ipairs(wanted) do t_insert(gems, { name = gem.name, level = gem.level, quality = gem.quality }) end
						entry.gain = sim({ { op = 'add_group', label = gg.label, slot = gg.slot, gems = gems } })
					else
						-- Each missing gem alone: added, replacing a support the guide does not use when the group is full.
						for k, gem in ipairs(entry.missing) do
							if not gem.later then
								local ops = { { op = 'add_gem', group = g.index, name = gem.name, level = gem.level, quality = gem.quality } }
								local wrong = entry.wrong[k]
								if wrong and entry.playerCount >= entry.guideCount then
									t_insert(ops, { op = 'gem', group = g.index, gem = wrong.index, enabled = false })
									gem.replaces = wrong.name
								end
								gem.gain = sim(ops)
							end
						end
						if #entry.levels > 0 then
							local ops = {}
							for _, lv in ipairs(entry.levels) do
								for _, gem in ipairs(g.gems) do
									if lower(gem.name) == lower(lv.name) then
										t_insert(ops, { op = 'gem', group = g.index, gem = gem.index, level = m_max(lv.to or 0, lv.from or 0), quality = m_max(lv.qTo or 0, lv.qFrom or 0) })
									end
								end
							end
							entry.levelGain = sim(ops)
							entry.levelOps = ops
						end
					end
				end
			end
		end
	end
	return out, mine
end

-- Items: every guide slot simulated in the player's build.
local function itemGap(guide, skip, simulate, levelling)
	local mine = {}
	for _, it in ipairs(gearItems()) do mine[it.slot] = it end
	local out = { slots = {}, have = 0, total = 0 }
	for _, gi in ipairs(guide.items or {}) do
		local isJewel = gi.slot:match('^Jewel') ~= nil
		local p = mine[gi.slot]
		local entry = { slot = gi.slot, guide = gi.name, base = gi.base, rarity = gi.rarity, player = p and p.name or nil, playerBase = p and p.base or nil, playerRarity = p and p.rarity or nil, mods = gi.rarity ~= 'UNIQUE' and gi.mods or nil }
		local same = p and lower(p.name) == lower(gi.name)
		if gi.rarity == 'UNIQUE' then
			entry.status = same and 'match' or 'missing unique'
		elseif gi.rarity == 'RARE' or gi.rarity == 'MAGIC' then
			entry.status = (p and (p.rarity == 'RARE' or p.rarity == 'MAGIC' or p.rarity == 'NORMAL')) and 'rare' or 'missing rare'
		else
			entry.status = same and 'match' or 'missing'
		end
		if entry.status ~= 'match' and skipped(skip, gi.slot, gi.name, p and p.name) then entry.status = 'accepted' end
		-- Levelling: links and cheap uniques matter, the guide's rares do not.
		if levelling and (entry.status == 'rare' or entry.status == 'missing rare') then entry.status = 'levelling rare' end
		if isJewel and not build.spec.allocNodes[tonumber(gi.slot:match('(%d+)'))] then entry.status = 'socket not allocated' end
		local counted = not isJewel and not gi.slot:match('^Flask') and entry.status ~= 'levelling rare'
		if counted then out.total = out.total + 1 end
		if simulate and entry.status ~= 'match' and entry.status ~= 'accepted' and entry.status ~= 'socket not allocated' and entry.status ~= 'levelling rare' then
			entry.gain = isJewel and jewelSim(gi.slot, gi.raw) or sim({ { op = 'equip', slot = gi.slot, text = gi.raw } })
		end
		-- A rare counts as matched when the guide's rare would not improve the build.
		if entry.status == 'rare' and entry.gain and entry.gain.dpsPct < 2 and entry.gain.ehpPct < 2 then entry.status = 'rare ok' end
		if counted and (entry.status == 'match' or entry.status == 'accepted' or entry.status == 'rare ok') then out.have = out.have + 1 end
		t_insert(out.slots, entry)
	end
	return out
end

-- Config options that differ (they explain number gaps without changing the build).
local SKIP_CONFIG = { buildName = true }
local function configGap(guide)
	local mine = configInput()
	local diff, values = {}, {}
	local labels = Ops.get_config_labels() or {}
	local keys = {}
	for k in pairs(guide.config or {}) do keys[k] = true end
	for k in pairs(mine) do keys[k] = true end
	for k in pairs(keys) do
		local gv, pv = (guide.config or {})[k], mine[k]
		if gv == false then gv = nil end
		if pv == false then pv = nil end
		if gv ~= pv and not SKIP_CONFIG[k] then
			t_insert(diff, { key = k, label = labels[k], guide = gv, player = pv })
			values[k] = gv == nil and false or gv
		end
	end
	t_sort(diff, function(a, b) return a.key < b.key end)
	return diff, values
end

-- Priorities -----------------------------------------------------------------------
-- What the character lacks most decides how gains are weighed:
-- 1. uncapped elemental resistances come first (the cap is a fact of the game);
-- 2. otherwise whichever of defence (EHP, weakest max hit) or damage is further
--    behind the guide stage gets the bigger weight; hardcore leans to defence.
local function weakestHit(s)
	local m
	for _, t in ipairs({ 'Physical', 'Fire', 'Cold', 'Lightning', 'Chaos' }) do
		local v = s and s[t .. 'MaximumHitTaken']
		if v and v > 0 and (not m or v < m) then m = v end
	end
	return m or 0
end

priorities = function(res, guide, opts)
	local me, g = res.stats or {}, guide.stats or {}
	local f = { reasons = {}, resMissing = {} }
	local ok, d = pcall(handlers.diagnose, {})
	local diag = ok and d and d.diagnosis
	for _, k in ipairs({ 'Fire', 'Cold', 'Lightning' }) do
		local r = diag and diag.resist and diag.resist[k]
		if r and r.value and r.max and r.value < r.max then
			f.resMissing[k:lower()] = r.max - r.value
			t_insert(f.reasons, string.format('%s resistance %d%% of %d%%', k, r.value, r.max))
		end
	end
	local function ratio(a, b) return b > 0 and a / b or 1 end
	f.dpsRatio = ratio(dpsOf(me), dpsOf(g))
	f.ehpRatio = ratio(me.TotalEHP or 0, g.TotalEHP or 0)
	f.hitRatio = ratio(weakestHit(me), weakestHit(g))
	local def = m_min(f.ehpRatio, f.hitRatio)
	local hc = opts.hardcore
	local function pct(v) return math.floor(v * 100 + 0.5) end
	if next(f.resMissing) then
		f.kind, f.title = 'resists', 'Cap your resistances first'
	elseif def < f.dpsRatio - 0.1 or (hc and def < 0.9 and def <= f.dpsRatio) then
		f.kind, f.title = 'defence', 'Defence is behind'
	elseif f.dpsRatio < def - 0.1 then
		f.kind, f.title = 'damage', 'Damage is behind'
	else
		f.kind, f.title = 'balanced', 'Damage and defence are even'
	end
	t_insert(f.reasons, string.format('vs the guide stage: DPS %d%%, EHP %d%%, weakest max hit %d%%', pct(f.dpsRatio), pct(f.ehpRatio), pct(f.hitRatio)))
	if f.kind == 'resists' or f.kind == 'defence' then f.wDps, f.wEhp = 1, hc and 4 or 3
	elseif f.kind == 'damage' then f.wDps, f.wEhp = 2, hc and 2 or 1
	else f.wDps, f.wEhp = 1, hc and 2 or 1 end
	if hc then t_insert(f.reasons, 'hardcore: defence counts more') end
	return f
end

-- One number per gain: weighted DPS and EHP percent, plus 2 per point of a
-- resistance that is still under its cap (minus 2 per point lost).
local function score(gn, f)
	if not gn or gn.error then return nil end
	local v = f.wDps * (gn.dpsPct or 0) + f.wEhp * (gn.ehpPct or 0)
	for k, miss in pairs(f.resMissing or {}) do
		local add = gn.res and gn.res[k] or 0
		if add > 0 then v = v + 2 * m_min(add, miss) elseif add < 0 then v = v + 2 * add end
	end
	gn.score = v
	return v
end

local function urlencode(str)
	return (tostring(str):gsub('[^%w%-_%.~]', function(c) return string.format('%%%02X', string.byte(c)) end))
end

local function jsonString(str)
	return '"' .. tostring(str):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

-- An instant-buyout search on pathofexile.com, opened by the player (no request is made here).
local function tradeLink(league, name, base)
	if not league or league == '' then return nil end
	local q = '{"query":{"status":{"option":"securable"},"name":' .. jsonString(name) .. (base and (',"type":' .. jsonString(base)) or '') .. '},"sort":{"price":"asc"}}'
	return 'https://www.pathofexile.com/trade/search/' .. urlencode(league) .. '?q=' .. urlencode(q)
end

-- Ranked next steps (no prices: agent-mcp adds those). Passives keep the path order
-- (a step comes after the step it builds on); "rush" is the best target 3 or more
-- points away, counting the points of its path.
rankPlan = function(res, f, params)
	local steps = res.tree.steps or {}
	local byIdx = {}
	for i, st in ipairs(steps) do
		st.idx = i
		byIdx[i] = st
		score(st.gain, f)
	end
	local function chainOf(st)
		local list, seen = {}, {}
		local cur = st
		while cur and not seen[cur.idx] do
			t_insert(list, 1, cur)
			seen[cur.idx] = true
			cur = cur.after and byIdx[cur.after] or nil
		end
		return list
	end
	local plan = { passives = {}, other = {}, free = (res.pointsAtLevel or 0) - (res.points or 0) }
	local best
	for _, st in ipairs(steps) do
		if st.gain and (st.gain.score or 0) > 0 then
			local chain = chainOf(st)
			local pts, sc = 0, 0
			for _, c in ipairs(chain) do
				pts = pts + (c.points or 0)
				sc = sc + (c.gain and c.gain.score or 0)
			end
			local rate = pts > 0 and sc / pts or 0
			if pts >= 3 and (not best or rate > best.rate) then best = { step = st, points = pts, rate = rate, chain = chain } end
		end
	end
	if best then
		local dps, ehp = 0, 0
		for _, c in ipairs(best.chain) do
			dps = dps + (c.gain and c.gain.dpsPct or 0)
			ehp = ehp + (c.gain and c.gain.ehpPct or 0)
		end
		plan.rush = { target = best.step.target, points = best.points, dpsPct = dps, ehpPct = ehp, idx = best.step.idx }
	end
	local order = {}
	for _, st in ipairs(steps) do
		if st.gain and (st.gain.score or 0) > 0 and not st.skippedSim then t_insert(order, st) end
	end
	t_sort(order, function(a, b) return a.gain.score / m_max(1, a.points or 1) > b.gain.score / m_max(1, b.points or 1) end)
	local taken = {}
	for _, st in ipairs(order) do
		for _, c in ipairs(chainOf(st)) do
			if not taken[c.idx] then
				taken[c.idx] = true
				t_insert(plan.passives, { idx = c.idx, text = table.concat(c.names or {}, ', '), target = c.target, points = c.points, gain = c.gain, kind = c.kind, nodes = c.nodes })
			end
		end
	end
	local league = params.league
	for _, g in ipairs(res.gems.groups or {}) do
		if g.absent and g.gain and not g.later and score(g.gain, f) and g.gain.score > 0 then
			local names = {}
			for _, x in ipairs(g.gems or {}) do t_insert(names, x.name) end
			t_insert(plan.other, { kind = 'skill group', text = 'New group: ' .. table.concat(names, ' + '), gain = g.gain, view = 'SKILLS' })
		end
		for _, x in ipairs(g.missing or {}) do
			if x.gain and not x.later and score(x.gain, f) and x.gain.score > 0 then
				t_insert(plan.other, { kind = 'gem', text = x.name .. ' in ' .. tostring(g.skill) .. (x.replaces and (' (instead of ' .. x.replaces .. ')') or ''), gain = x.gain, view = 'SKILLS', name = x.name })
			end
		end
		if g.levelGain and score(g.levelGain, f) and g.levelGain.score > 0 then
			local names = {}
			for _, l in ipairs(g.levels or {}) do t_insert(names, l.name .. ' to ' .. tostring(l.to) .. '/' .. tostring(l.qTo)) end
			t_insert(plan.other, { kind = 'gem levels', text = 'Level ' .. table.concat(names, ', '), gain = g.levelGain, view = 'SKILLS' })
		end
	end
	for _, it in ipairs(res.items.slots or {}) do
		if it.gain and score(it.gain, f) and it.gain.score > 0 then
			local unique = it.rarity == 'UNIQUE'
			local short = tostring(it.guide or ''):match('^([^,]+)') or it.guide
			t_insert(plan.other, { kind = it.slot:match('^Jewel') and 'jewel' or 'item', slot = it.slot,
				text = it.slot .. ': ' .. (unique and short or ('rare ' .. tostring(it.base or ''))), gain = it.gain, view = 'ITEMS',
				unique = unique, name = unique and short or nil, base = it.base,
				link = unique and params.playMode ~= 'ssf' and tradeLink(league, short, it.base) or nil })
		end
	end
	t_sort(plan.other, function(a, b) return a.gain.score > b.gain.score end)
	return plan
end

-- Stage detection --------------------------------------------------------------------
-- A levelling character (below maps) is matched to the levelling stages by passive
-- points; others by how alike tree, items and gems are.
detectStage = function(stages, me, level, pAtLevel)
	local mine, myGems = {}, {}
	for _, id in ipairs(me.nodes or {}) do mine[id] = true end
	for _, gname in ipairs(me.gems or {}) do myGems[lower(gname)] = true end
	local levellingStages = {}
	for _, st in ipairs(stages) do if st.levelling then t_insert(levellingStages, st) end end
	if level < MAPS_LEVEL and #levellingStages > 0 then
		t_sort(levellingStages, function(a, b) return a.points < b.points end)
		local pick = levellingStages[1]
		for _, st in ipairs(levellingStages) do if st.points <= (me.points or 0) + 2 then pick = st end end
		return { index = pick.index, levelling = true,
			reason = string.format('levelling: %d passive points, nearest levelling stage', me.points or 0) }
	end
	local best
	for _, st in ipairs(stages) do
		local both, union = 0, 0
		local theirs = {}
		for _, id in ipairs(st.nodes or {}) do
			theirs[id] = true
			if mine[id] then both = both + 1 end
		end
		for _ in pairs(mine) do union = union + 1 end
		for id in pairs(theirs) do if not mine[id] then union = union + 1 end end
		local tree = both / m_max(1, union)
		local slots, same = 0, 0
		for slot, name in pairs(st.items or {}) do
			slots = slots + 1
			if me.items and me.items[slot] and lower(me.items[slot]) == lower(name) then same = same + 1 end
		end
		local items = same / m_max(1, slots)
		local gHave = 0
		for _, gname in ipairs(st.gems or {}) do if myGems[lower(gname)] then gHave = gHave + 1 end end
		local gems = gHave / m_max(1, #(st.gems or {}))
		local sc = 0.6 * tree + 0.2 * items + 0.2 * gems
		if (st.points or 0) > pAtLevel + 3 then sc = sc - 0.15 end
		if not best or sc > best.score then best = { index = st.index, score = sc, tree = tree, items = items, gems = gems } end
	end
	best.reason = string.format('tree %d%%, items %d%%, gems %d%% alike', math.floor(best.tree * 100 + 0.5), math.floor(best.items * 100 + 0.5), math.floor(best.gems * 100 + 0.5))
	best.levelling = level < MAPS_LEVEL
	return best
end

-- params: { stages = guide_stages{all}.stages, me = guide_stages().stages[1], level, pointsAtLevel }
handlers.guide_detect = function(params)
	if type(params.stages) ~= 'table' or #params.stages == 0 then return { ok = false, error = 'stages required' } end
	local res = detectStage(params.stages, type(params.me) == 'table' and params.me or {}, tonumber(params.level) or 1, tonumber(params.pointsAtLevel) or 0)
	res.ok = true
	return res
end

-- The Guide tab reads the guide from a CompareEntry (a second build PoB calculates
-- on its own) and runs these same handlers on it.
handlers._withBuild = function(other, fn, ...)
	local saved = build
	build = other
	local ok, res = pcall(fn, ...)
	build = saved
	if not ok then return { ok = false, error = tostring(res) } end
	return res
end

-- params: { guide = guide_data result, skip = {names}, simulate = bool, maxSteps, levelling, hardcore, league, playMode }
handlers.guide_gap = function(params)
	local guide = params.guide
	if type(guide) ~= 'table' or type(guide.nodes) ~= 'table' then return { ok = false, error = 'guide data missing (guide_data result expected)' } end
	local skip = {}
	for _, s in ipairs(type(params.skip) == 'table' and params.skip or {}) do skip[lower(s)] = true end
	local simulate = params.simulate ~= false
	recalc()
	local spec = build.spec
	local now = stats()
	local res = { ok = true, name = build.buildName, level = tonumber(build.characterLevel), className = spec.curClassName,
		ascendancy = spec.curAscendClassName, points = select(1, spec:CountAllocNodes()), pointsAtLevel = pointsAtLevel(),
		stats = now, guideStats = guide.stats, mainSkill = handlers.key_stats({}).mainSkill }
	-- Levelling: the stage is a levelling one, or the character has not reached maps yet.
	local levelling = params.levelling == true or (tonumber(build.characterLevel) or 1) < MAPS_LEVEL
	res.levelling = levelling
	res.tree = treeGap(guide, skip, simulate, tonumber(params.maxSteps), levelling)
	res.gems = gemGap(guide, skip, simulate, tonumber(build.characterLevel) or 1)
	res.items = itemGap(guide, skip, simulate, levelling)
	local configDiff, configValues = configGap(guide)
	res.config = configDiff

	-- What explains the gap: each part of the guide applied on its own, then all together.
	if simulate then
		local itemOps, gemOps, treeOps = {}, {}, {}
		for _, s in ipairs(res.items.slots) do
			if s.gain and not s.gain.failed and not s.slot:match('^Jewel') then
				for _, gi in ipairs(guide.items) do if gi.slot == s.slot then t_insert(itemOps, { op = 'equip', slot = gi.slot, text = gi.raw }) end end
			end
		end
		for _, g in ipairs(res.gems.groups) do
			if g.group then
				for _, gem in ipairs(g.missing) do
					if not gem.later then t_insert(gemOps, { op = 'add_gem', group = g.group, name = gem.name, level = gem.level, quality = gem.quality }) end
				end
				for _, w in ipairs(g.wrong) do t_insert(gemOps, { op = 'gem', group = g.group, gem = w.index, enabled = false }) end
				for _, lv in ipairs(g.levelOps or {}) do t_insert(gemOps, lv) end
			elseif g.gems and not g.later then
				local gems = {}
				for _, gem in ipairs(g.gems) do t_insert(gems, { name = gem.name, level = gem.level, quality = gem.quality }) end
				t_insert(gemOps, { op = 'add_group', slot = g.slot, gems = gems })
			end
		end
		local nodesInOrder = {}
		for _, step in ipairs(res.tree.steps or {}) do
			for _, id in ipairs(step.nodes or {}) do t_insert(nodesInOrder, id) end
		end
		if #nodesInOrder > 0 then t_insert(treeOps, { op = 'alloc', nodes = nodesInOrder }) end
		local extraIds = {}
		for _, e in ipairs(res.tree.extra or {}) do t_insert(extraIds, e.id) end
		if #extraIds > 0 and not levelling then t_insert(treeOps, { op = 'dealloc', nodes = extraIds }) end
		for _, step in ipairs(res.tree.steps or {}) do
			if step.mastery then t_insert(treeOps, { op = 'mastery', node = step.mastery.id, effect = step.mastery.effect }) end
		end
		local configOps = next(configValues) and { { op = 'config', values = configValues } } or {}
		local explain = { tree = res.tree.all, items = sim(itemOps), gems = sim(gemOps), config = sim(configOps) }
		local all = {}
		for _, list in ipairs({ treeOps, itemOps, gemOps, configOps }) do for _, o in ipairs(list) do t_insert(all, o) end end
		explain.all = sim(all)
		res.explain = explain
	end
	res.focus = priorities(res, guide, { hardcore = params.hardcore == true })
	res.plan = rankPlan(res, res.focus, params)
	return res
end
