-- Agent Edition advice handlers: support gems, boss check, jewels, item affixes, notes.
-- Loaded by Tools.lua with (handlers, Ops, shared). Everything is simulated in
-- PoB and the build is put back exactly as it was.
local handlers, Ops, shared = ...

local t_insert = table.insert
local m_floor, m_min, m_max = math.floor, math.min, math.max
local num, dpsOf, pctChange, strip = shared.num, shared.dpsOf, shared.pctChange, shared.strip
local recalc, mainOutput, assumptions, mainSkillName = shared.recalc, shared.mainOutput, shared.assumptions, shared.mainSkillName
local capture, restore = shared.capture, shared.restore

-- Run fn with the build free to be changed; whatever happens, restore it afterwards.
local function simulate(fn)
	local state = capture()
	local ok, res = pcall(fn)
	local errors = restore(state)
	if not ok then return { ok = false, error = tostring(res) } end
	if #errors > 0 then res.rollbackProblem = table.concat(errors, '; ') end
	return res
end

-- Support gems ---------------------------------------------------------------
-- params: { group?, replace? (gem number), add? (bool), awakened? (default true), limit? }
-- 1. What each current support is worth (DPS lost when it is switched off).
-- 2. Every support gem that can support the skill, tried in place of the weakest
--    one (or as an extra link), ranked by DPS.
handlers.suggest_gems = function(params)
	local skillsTab = build.skillsTab
	local groupIndex = tonumber(params.group) or build.mainSocketGroup
	local group = skillsTab.socketGroupList[groupIndex]
	if not group then return { ok = false, error = 'no skill group ' .. tostring(groupIndex) .. ' (build_summary lists them)' } end
	return simulate(function()
		if build.mainSocketGroup ~= groupIndex then
			build.mainSocketGroup = groupIndex
			build.calcsTab.input.skill_number = groupIndex
		end
		local function measure()
			skillsTab:ProcessSocketGroup(group)
			local o = recalc()
			return dpsOf(o), o
		end
		local baseDps, baseOut = measure()
		local skillName = mainSkillName()
		if baseDps <= 0 then error('the skill in group ' .. groupIndex .. ' deals no damage in PoB (pick the damage skill group, or check the main skill)') end
		local baseMana = num(baseOut.ManaCost) or 0
		local baseFlags = {}
		do
			local main = build.calcsTab.mainEnv and build.calcsTab.mainEnv.player.mainSkill
			for k, v in pairs(main and main.skillFlags or {}) do baseFlags[k] = v end
		end

		-- The highest level of a gem this character's level allows (a level 20 gem needs about level 70).
		local charLevel = tonumber(build.characterLevel) or 100
		local function usableLevel(gemData)
			local top = m_min(gemData.naturalMaxLevel or 20, 20)
			local levels = gemData.grantedEffect and gemData.grantedEffect.levels or {}
			for l = top, 1, -1 do
				local req = levels[l] and levels[l].levelRequirement
				if not req or req <= charLevel then return l end
			end
			return nil -- even level 1 of this gem needs a higher character level
		end

		-- 1. Current supports (and gems that could simply be levelled up)
		local current, inGroup, levelUps = {}, {}, {}
		for i, gem in ipairs(group.gemList) do
			local name = gem.nameSpec or ''
			inGroup[name:lower()] = true
			local isSupport = gem.gemData and gem.gemData.grantedEffect and gem.gemData.grantedEffect.support
			if gem.gemData and gem.enabled ~= false then
				local usable = usableLevel(gem.gemData)
				if usable and (gem.level or 1) < usable then
					local old = gem.level
					gem.level = usable
					local dps = measure()
					gem.level = old
					local gain = pctChange(dps, baseDps)
					if gain > 0.5 then t_insert(levelUps, { gem = i, name = name, from = old, to = usable, dpsPct = gain }) end
				end
			end
			if isSupport and gem.enabled ~= false then
				gem.enabled = false
				local dps = measure()
				gem.enabled = true
				t_insert(current, { gem = i, name = name, level = gem.level, quality = gem.quality, lossPct = -pctChange(dps, baseDps) })
			end
		end
		table.sort(levelUps, function(a, b) return a.dpsPct > b.dpsPct end)
		measure()
		table.sort(current, function(a, b) return a.lossPct < b.lossPct end)

		local mode, target = 'add', nil
		if params.add ~= true then
			target = tonumber(params.replace)
			if target then
				local found
				for _, c in ipairs(current) do if c.gem == target then found = c end end
				if not found then error('gem ' .. target .. ' in group ' .. groupIndex .. ' is not an active support gem') end
			elseif current[1] then
				target = current[1].gem
			end
			if target then mode = 'replace' end
		end

		-- 2. Candidates
		local activeSkill = build.calcsTab.mainEnv and build.calcsTab.mainEnv.player and build.calcsTab.mainEnv.player.mainSkill
		local candidates, tried = {}, 0
		local allowAwakened = params.awakened ~= false
		for _, gemData in pairs(build.data.gems) do
			local effect = gemData.grantedEffect
			local name = gemData.name
			if effect and effect.support and name and not inGroup[name:lower()] and not effect.fromItem
				and (allowAwakened or not name:match('^Awakened ')) then
				local can = true
				if activeSkill then
					local okCan, r = pcall(calcLib.canGrantedEffectSupportActiveSkill, effect, activeSkill)
					if okCan then can = r end
				end
				local level = can and usableLevel(gemData)
				if can and level then
					local instance = {
						nameSpec = name, gemId = gemData.id, skillId = gemData.grantedEffectId, gemData = gemData,
						level = level, quality = 20, qualityId = 'Default',
						enabled = true, enableGlobal1 = true, enableGlobal2 = true, count = 1,
					}
					local old
					if mode == 'replace' then
						old = group.gemList[target]
						group.gemList[target] = instance
					else
						t_insert(group.gemList, instance)
					end
					local okCalc, dps, o = pcall(measure)
					if mode == 'replace' then group.gemList[target] = old else table.remove(group.gemList) end
					tried = tried + 1
					if okCalc and dps then
						local c = { name = name, level = instance.level, dpsPct = pctChange(dps, baseDps), awakened = name:match('^Awakened ') and true or nil }
						-- Supports that turn the skill into a mine, trap, totem or triggered skill change how it is played.
						local flags = build.calcsTab.mainEnv and build.calcsTab.mainEnv.player.mainSkill and build.calcsTab.mainEnv.player.mainSkill.skillFlags or {}
						for _, flag in ipairs({ 'mine', 'trap', 'totem', 'brand' }) do
							if flags[flag] and not baseFlags[flag] then c.playstyle = flag end
						end
						if not c.playstyle and (name:find('Barrage') or name:find('^Cast ') or name:find('Spellslinger') or name:find('Unleash') or name:find('Archmage') or name:find('Manaforged') or name:find('Sacred Wisps')) then c.playstyle = 'changes how the skill is used' end
						local mana = num(o.ManaCost) or 0
						if mana ~= baseMana then c.manaCost = mana end
						if (num(o.ManaUnreserved) or 0) < mana and mana > 0 then c.warning = 'mana cost ' .. mana .. ' is more than the unreserved mana' end
						t_insert(candidates, c)
					end
				end
			end
		end
		measure()
		table.sort(candidates, function(a, b) return a.dpsPct > b.dpsPct end)
		local limit = m_min(m_max(tonumber(params.limit) or 8, 1), 25)
		local better, normal, playstyle = 0, {}, {}
		for _, c in ipairs(candidates) do
			if c.playstyle then
				if c.dpsPct > 0.05 and #playstyle < 4 then t_insert(playstyle, c) end
			else
				if c.dpsPct > 0.05 then better = better + 1 end
				if #normal < limit then t_insert(normal, c) end
			end
		end
		candidates = normal
		local targetName
		for _, c in ipairs(current) do if c.gem == target then targetName = c.name end end
		return { ok = true, group = groupIndex, skill = skillName, baseDps = baseDps, manaCost = baseMana, current = current,
			mode = mode, target = target, targetName = targetName, candidates = candidates, playstyle = playstyle, tried = tried, better = better,
			levelUps = levelUps, characterLevel = charLevel,
			assumptions = assumptions() }
	end)
end

-- Boss check -------------------------------------------------------------------
-- params: { boss = "shaper"|"maven"|...|"all", uber = bool }
-- Uses PoB's own boss skill presets (Data/BossSkills): for each skill of the boss
-- PoB works out how hard it hits this character and how many hits the pool takes.
handlers.boss_check = function(params)
	local list = data.bossSkillsList or {}
	local want = tostring(params.boss or 'all'):lower():gsub('^uber%s+', '')
	local uber = params.uber == true or tostring(params.boss or ''):lower():match('^uber') ~= nil
	local skills = {}
	for _, entry in ipairs(list) do
		if entry.val ~= 'None' and (want == 'all' or want == 'pinnacle' or entry.val:lower():find(want, 1, true)) then t_insert(skills, entry.val) end
	end
	if #skills == 0 then
		local names = {}
		for _, entry in ipairs(list) do if entry.val ~= 'None' then t_insert(names, entry.val) end end
		return { ok = false, error = 'PoB has no boss skill preset matching "' .. tostring(params.boss) .. '". Presets: ' .. table.concat(names, ', ') .. '. Use a boss name (shaper, maven, sirus, ...) or "all".' }
	end
	return simulate(function()
		local results = {}
		local dps
		for _, skill in ipairs(skills) do
			local r, err = Ops.set_config({ enemyIsBoss = uber and 'Uber' or 'Pinnacle', presetBossSkills = skill })
			if not r then error(err) end
			local o = recalc()
			dps = dps or dpsOf(o)
			local info = data.bossSkills and data.bossSkills[skill] or {}
			local byType = {}
			for _, dt in ipairs({ 'Physical', 'Lightning', 'Cold', 'Fire', 'Chaos' }) do
				local v = num(o[dt .. 'TakenHit'])
				if v and v >= 1 then byType[dt] = m_floor(v) end
			end
			t_insert(results, {
				skill = skill,
				overTime = info.DamageType == 'DamageOverTime' or nil,
				enemyDamage = num(o.totalEnemyDamage) and m_floor(o.totalEnemyDamage),
				taken = num(o.totalTakenHit) and m_floor(o.totalTakenHit),
				takenByType = byType,
				hitsToDie = num(o.NumberOfDamagingHits),
				ehp = num(o.TotalEHP) and m_floor(o.TotalEHP),
				damageType = info.DamageType,
				note = info.tooltip and strip(info.tooltip):gsub('%s+', ' ') or nil,
			})
		end
		local o = mainOutput()
		return { ok = true, uber = uber, results = results, dps = dps, mainSkill = mainSkillName(),
			life = num(o.Life), energyShield = num(o.EnergyShield), assumptions = assumptions() }
	end)
end

-- Notes --------------------------------------------------------------------------
-- params: { append = "text" } or { set = "text" }; no params reads them.
handlers.notes = function(params)
	local tab = build.notesTab
	local text = tab.controls and tab.controls.edit and tab.controls.edit.buf or tab.lastContent or ''
	if type(params.set) == 'string' or type(params.append) == 'string' then
		if type(params.set) == 'string' then text = params.set
		else text = (text ~= '' and (text:gsub('%s+$', '') .. '\n\n') or '') .. params.append end
		if tab.controls and tab.controls.edit then tab.controls.edit:SetText(text) end
		tab.lastContent = text
		tab.modFlag = true
		build.modFlag = true
	end
	return { ok = true, notes = strip(text), length = #text }
end

-- Item affixes ---------------------------------------------------------------------
-- "+(8-12) to Strength" and "+10 to Strength" both become "+# to Strength".
local function template(line)
	return (line:gsub('%(%-?[%d%.]+%-%-?[%d%.]+%)', '#'):gsub('%-?%d+%.?%d*', '#'))
end
-- The number ranges of a mod line, in order: {min, max} per '#'.
local function ranges(line)
	local out = {}
	local pos = 1
	while pos <= #line do
		local s, e, a, b = line:find('%((%-?[%d%.]+)%-(%-?[%d%.]+)%)', pos)
		local s2, e2, v = line:find('(%-?%d+%.?%d*)', pos)
		if s and (not s2 or s <= s2) then
			t_insert(out, { tonumber(a), tonumber(b) })
			pos = e + 1
		elseif s2 then
			t_insert(out, { tonumber(v), tonumber(v) })
			pos = e2 + 1
		else break end
	end
	return out
end
local function values(line)
	local out = {}
	for v in line:gmatch('%-?%d+%.?%d*') do t_insert(out, tonumber(v)) end
	return out
end
local function fits(modLine, itemLine)
	if template(modLine) ~= template(itemLine) then return false end
	local r, v = ranges(modLine), values(itemLine)
	if #r ~= #v then return false end
	for i = 1, #r do
		local lo, hi = m_min(r[i][1], r[i][2]), m_max(r[i][1], r[i][2])
		if v[i] < lo - 0.001 or v[i] > hi + 0.001 then return false end
	end
	return true
end

-- params: { slot = "Ring 1" } or { text = "<item text>" }
handlers.classify_item = function(params)
	local item
	if type(params.text) == 'string' and params.text ~= '' then
		local ok, parsed = pcall(new, 'Item', params.text)
		if not ok or not parsed or not parsed.base then return { ok = false, error = 'PoB could not read that item text' } end
		item = parsed
	else
		local slot = build.itemsTab.slots[tostring(params.slot)]
		if not slot then return { ok = false, error = 'unknown slot "' .. tostring(params.slot) .. '" (build_summary lists the slot names)' } end
		item = slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId]
		if not item then return { ok = false, error = 'no item in ' .. tostring(params.slot) } end
	end
	local res = { name = strip(item.title or item.name), base = item.baseName, rarity = item.rarity, itemLevel = item.itemLevel, mods = {}, notes = {} }
	if item.rarity == 'UNIQUE' or item.rarity == 'RELIC' then
		res.notes[1] = 'Unique items have fixed mods: there are no prefixes or suffixes to classify or craft.'
		return { ok = true, item = res }
	end
	local pool = item.affixes or data.itemMods.Item
	-- Rollable affixes this base can get, by template of their first line.
	local eligible = {}
	for id, mod in pairs(pool) do
		if (mod.type == 'Prefix' or mod.type == 'Suffix') and mod[1] then
			local okW, weight = pcall(item.GetModSpawnWeight, item, mod)
			if okW and weight and weight > 0 then t_insert(eligible, mod) end
		end
	end
	local bench = {}
	for _, mod in ipairs(data.masterMods or {}) do
		if mod.types and mod.types[item.type] and mod[1] then t_insert(bench, mod) end
	end
	local function tierOf(mod)
		local same = {}
		for _, m in ipairs(eligible) do if m.group == mod.group and #m == #mod and template(m[1]) == template(mod[1]) then t_insert(same, m) end end
		table.sort(same, function(a, b) return a.level > b.level end)
		for i, m in ipairs(same) do if m == mod then return i, #same end end
		return nil, #same
	end
	local lines = {}
	for _, l in ipairs(item.explicitModLines or {}) do
		local text = l.line
		if l.range and itemLib and itemLib.applyRange then
			local okR, applied = pcall(itemLib.applyRange, text, l.range, l.valueScalar)
			if okR and applied then text = applied end
		end
		t_insert(lines, { text = strip(text), crafted = l.crafted and true or nil, fractured = l.fractured and true or nil })
	end
	local used = {}
	local prefixes, suffixes = 0, 0
	local function record(mod, idxs, source)
		local tier, tiers
		if source == 'rolled' then tier, tiers = tierOf(mod) end
		local texts = {}
		for _, i in ipairs(idxs) do used[i] = true t_insert(texts, lines[i].text) end
		local range = {}
		for i = 1, #mod do t_insert(range, mod[i]) end
		t_insert(res.mods, { lines = texts, type = mod.type, name = mod.affix, tier = tier, tiers = tiers, level = mod.level,
			range = range, source = source, fractured = lines[idxs[1]].fractured })
		if mod.type == 'Prefix' then prefixes = prefixes + 1 else suffixes = suffixes + 1 end
	end
	local function match(mod, wantCrafted)
		local idxs = {}
		for m = 1, #mod do
			local found
			for i, l in ipairs(lines) do
				if not used[i] and (l.crafted == true) == wantCrafted and fits(mod[m], l.text) then
					local taken = false
					for _, j in ipairs(idxs) do if j == i then taken = true end end
					if not taken then found = i break end
				end
			end
			if not found then return nil end
			t_insert(idxs, found)
		end
		return idxs
	end
	-- Bench crafts first (they are marked on the item), then rolled mods: single lines, then hybrids.
	table.sort(bench, function(a, b) return #a > #b end)
	for _, mod in ipairs(bench) do
		local idxs = match(mod, true)
		if idxs then record(mod, idxs, 'bench') end
	end
	table.sort(eligible, function(a, b) if #a ~= #b then return #a < #b end return a.level > b.level end)
	for _, mod in ipairs(eligible) do
		local idxs = match(mod, false)
		if idxs then record(mod, idxs, 'rolled') end
	end
	-- Two single-line mods that could also be one hybrid mod.
	for _, mod in ipairs(eligible) do
		if #mod > 1 then
			local hits = 0
			for m = 1, #mod do
				for _, found in ipairs(res.mods) do
					if found.source == 'rolled' and #found.lines == 1 and template(mod[m]) == template(found.lines[1]) then hits = hits + 1 break end
				end
			end
			if hits == #mod then
				t_insert(res.notes, 'Lines matching "' .. mod.affix .. '" (' .. mod.type .. ', hybrid: ' .. table.concat({ unpack(mod, 1, #mod) }, ' / ') .. ') may be one hybrid ' .. mod.type:lower() .. ' instead of separate mods; check in game with Alt held.')
				break
			end
		end
	end
	res.unmatched = {}
	for i, l in ipairs(lines) do
		if not used[i] then t_insert(res.unmatched, l.text .. (l.crafted and ' (crafted)' or '')) end
	end
	local limit = item.rarity == 'MAGIC' and 1 or ((item.type == 'Jewel') and 2 or 3)
	res.prefixes = { used = prefixes, limit = limit }
	res.suffixes = { used = suffixes, limit = limit }
	if prefixes > limit or suffixes > limit then
		t_insert(res.notes, 'More ' .. (prefixes > limit and 'prefixes' or 'suffixes') .. ' matched than an item can hold: some lines are special mods (essence, influence, implicit-like) or the text is not a real item.')
	end
	if #res.unmatched > 0 then
		t_insert(res.notes, 'Unmatched lines are not in PoB\'s rollable or bench mod tables for this base (essence, veiled, influence, eldritch or combined values): open slots may be fewer than shown.')
	end
	return { ok = true, item = res }
end

-- Jewels ---------------------------------------------------------------------------
-- params: { kind = "jewel"|"abyss"|"watchers_eye"|"cluster", focus, limit, socket? }
-- Tries every jewel mod (best tier, top roll) on its own in an allocated jewel
-- socket, against the same socket holding a blank jewel.
local function topRoll(line)
	return (line:gsub('%((%-?[%d%.]+)%-(%-?[%d%.]+)%)', function(a, b) return b end))
end
local JEWEL_BASES = { { 'Crimson Jewel', 'Crimson' }, { 'Viridian Jewel', 'Viridian' }, { 'Cobalt Jewel', 'Cobalt' } }
local ABYSS_BASES = { { 'Murderous Eye Jewel', 'Murderous' }, { 'Searching Eye Jewel', 'Searching' }, { 'Hypnotic Eye Jewel', 'Hypnotic' }, { 'Ghastly Eye Jewel', 'Ghastly' } }

handlers.suggest_jewels = function(params)
	local kind = tostring(params.kind or 'jewel'):lower()
	local focus = params.focus or 'balanced'
	local spec = build.spec
	local calc = build.calcsTab:GetMiscCalculator()
	local function score(o, base)
		local d, e = pctChange(dpsOf(o), dpsOf(base)), pctChange(num(o.TotalEHP) or 0, num(base.TotalEHP) or 0)
		local s = focus == 'dps' and d or (focus == 'defence' and e or (d + 0.6 * e))
		return s, d, e
	end
	local limit = m_min(m_max(tonumber(params.limit) or 10, 1), 30)
	local out, evaluated = {}, 0

	if kind == 'cluster' then
		local okBase, base = pcall(calc, {})
		if not okBase then return { ok = false, error = 'base calculation failed: ' .. tostring(base) } end
		for name, node in pairs(spec.tree.clusterNodeMap or {}) do
			if node.modKey and node.modKey ~= '' and not node.isKeystone then
				local okCalc, o = pcall(calc, { addNodes = { [node] = true } })
				evaluated = evaluated + 1
				if okCalc and type(o) == 'table' then
					local s, d, e = score(o, base)
					if s > 0.05 then t_insert(out, { name = name, stats = node.sd, dpsPct = d, ehpPct = e, lifeDelta = (num(o.Life) or 0) - (num(base.Life) or 0), score = s }) end
				end
			end
		end
		table.sort(out, function(a, b) return a.score > b.score end)
		while #out > limit do table.remove(out) end
		return { ok = true, kind = kind, focus = focus, mods = out, evaluated = evaluated, assumptions = assumptions(),
			baseline = 'each cluster notable added on its own (the jewel\'s small passives and the path are not counted)' }
	end

	-- Which socket to test in
	local slotName, occupied
	for name, slot in pairs(build.itemsTab.slots) do
		local nodeId = tonumber(name:match('^Jewel (%d+)$'))
		if nodeId and spec.allocNodes[nodeId] and (not params.socket or tostring(params.socket) == name or tonumber(params.socket) == nodeId) then
			local hasItem = slot.selItemId and slot.selItemId > 0
			if not slotName or (occupied and not hasItem) then slotName, occupied = name, hasItem end
		end
	end
	if not slotName then return { ok = false, error = 'no allocated jewel socket found: allocate one on the passive tree first (tree_search type "jewel")' } end

	local bases = kind == 'abyss' and ABYSS_BASES or JEWEL_BASES
	local function makeItem(baseName, lines, unique)
		local text = (unique and 'Rarity: UNIQUE\nWatcher\'s Eye\n' or 'Rarity: RARE\nAdvisor Jewel\n') .. baseName .. '\n' .. table.concat(lines, '\n')
		local ok, item = pcall(new, 'Item', text)
		return ok and item and item.base and item or nil
	end
	local blank = makeItem(kind == 'watchers_eye' and 'Prismatic Jewel' or bases[1][1], {}, kind == 'watchers_eye')
	local okBase, base = pcall(calc, { repSlotName = slotName, repItem = blank })
	if not okBase then return { ok = false, error = 'base calculation failed: ' .. tostring(base) } end

	local candidates = {}
	if kind == 'watchers_eye' then
		for _, entry in ipairs(data.uniqueMods['Watcher\'s Eye'] or {}) do
			local lines = {}
			for _, line in ipairs(entry.mod) do t_insert(lines, topRoll(line)) end
			if #lines > 0 then t_insert(candidates, { lines = lines, base = 'Prismatic Jewel', unique = true }) end
		end
	else
		local pool = kind == 'abyss' and data.itemMods.JewelAbyss or data.itemMods.Jewel
		local best = {}
		local testItems = {}
		for _, b in ipairs(bases) do testItems[b[2]] = makeItem(b[1], {}) end
		for id, mod in pairs(pool or {}) do
			if (mod.type == 'Prefix' or mod.type == 'Suffix') and mod[1] then
				local rollsOn = {}
				for _, b in ipairs(bases) do
					local okW, w = pcall(testItems[b[2]].GetModSpawnWeight, testItems[b[2]], mod)
					if okW and w and w > 0 then t_insert(rollsOn, b[2]) end
				end
				if #rollsOn > 0 then
					local key = mod.group .. '|' .. template(mod[1])
					if not best[key] or mod.level > best[key].mod.level then best[key] = { mod = mod, rollsOn = rollsOn } end
				end
			end
		end
		for _, entry in pairs(best) do
			local lines = {}
			for i = 1, #entry.mod do t_insert(lines, topRoll(entry.mod[i])) end
			t_insert(candidates, { lines = lines, base = bases[1][1], rollsOn = entry.rollsOn, affix = entry.mod.type, level = entry.mod.level })
		end
	end

	for _, c in ipairs(candidates) do
		local item = makeItem(c.base, c.lines, c.unique)
		if item then
			local okCalc, o = pcall(calc, { repSlotName = slotName, repItem = item })
			evaluated = evaluated + 1
			if okCalc and type(o) == 'table' then
				local s, d, e = score(o, base)
				if s > 0.05 then
					t_insert(out, { stats = c.lines, dpsPct = d, ehpPct = e, lifeDelta = (num(o.Life) or 0) - (num(base.Life) or 0), score = s,
						rollsOn = c.rollsOn, affix = c.affix, level = c.level })
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.score > b.score end)
	while #out > limit do table.remove(out) end
	return { ok = true, kind = kind, focus = focus, mods = out, evaluated = evaluated, socket = slotName, socketOccupied = occupied and true or false,
		assumptions = assumptions(), baseline = 'each mod alone at its best tier and top roll, compared with a blank jewel in ' .. slotName }
end
