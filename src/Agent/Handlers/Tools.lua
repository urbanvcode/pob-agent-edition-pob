-- Agent Edition tool handlers: the calls agent-mcp's tools are built on.
-- Loaded by Core.lua with (handlers, BuildOps, op). Everything here works on
-- the global `build`, in the live window and in the headless runner alike.
local handlers, Ops, op, DIR = ...

local t_insert = table.insert
local m_floor, m_min, m_max = math.floor, math.min, math.max

local function num(v)
	if type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge then return v end
	return nil
end

local function mainOutput()
	return Ops.get_main_output()
end

local function recalc()
	build.buildFlag = true
	return mainOutput()
end

local function strip(text)
	return (tostring(text or ''):gsub('%^x%x%x%x%x%x%x', ''):gsub('%^%d', ''))
end

local function dpsOf(o)
	if not o then return 0 end
	if num(o.FullDPS) and o.FullDPS > 0 then return o.FullDPS end
	return num(o.CombinedDPS) or num(o.TotalDPS) or 0
end

local function pctChange(a, b)
	if not b or b <= 0 then return 0 end
	return (a - b) / b * 100
end

-- Config assumptions --------------------------------------------------------
-- Every number PoB shows depends on these; results name them so the AI can.
local BOSS_LABEL = { None = 'no boss', Boss = 'standard boss', Pinnacle = 'pinnacle boss', Uber = 'uber pinnacle boss' }

local function activeFlasks()
	local list = {}
	local set = build.itemsTab and build.itemsTab.activeItemSet
	for i = 1, 5 do
		local slotName = 'Flask ' .. i
		local slot = build.itemsTab.slots[slotName]
		local item = slot and slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId]
		if item and set and set[slotName] and set[slotName].active then
			t_insert(list, item.title or item.baseName or item.name)
		end
	end
	return list
end

local function assumptions()
	local input = build.configTab and build.configTab.input or {}
	local parts = {}
	t_insert(parts, 'enemy: ' .. (BOSS_LABEL[input.enemyIsBoss or 'Pinnacle'] or tostring(input.enemyIsBoss)))
	local charges = {}
	if input.usePowerCharges then t_insert(charges, 'power') end
	if input.useFrenzyCharges then t_insert(charges, 'frenzy') end
	if input.useEnduranceCharges then t_insert(charges, 'endurance') end
	t_insert(parts, 'charges: ' .. (#charges > 0 and table.concat(charges, '+') or 'none'))
	local flasks = activeFlasks()
	t_insert(parts, 'flasks on: ' .. (#flasks > 0 and table.concat(flasks, ', ') or 'none'))
	local other = 0
	for k, v in pairs(input) do
		if k ~= 'enemyIsBoss' and k ~= 'usePowerCharges' and k ~= 'useFrenzyCharges' and k ~= 'useEnduranceCharges'
			and v ~= false and v ~= 0 and v ~= '' and k ~= 'bandit' and k ~= 'pantheonMajorGod' and k ~= 'pantheonMinorGod' then
			other = other + 1
		end
	end
	if other > 0 then t_insert(parts, other .. ' other config options set') end
	return table.concat(parts, '; ')
end

local function mainSkillName()
	local env = build.calcsTab and build.calcsTab.mainEnv
	local skill = env and env.player and env.player.mainSkill
	local effect = skill and skill.activeEffect and skill.activeEffect.grantedEffect
	return effect and effect.name or nil
end

-- Stats -----------------------------------------------------------------------
-- params: { fields = {names}, match = "lua pattern, case-insensitive" }
handlers.stats = function(params)
	local output, err = mainOutput()
	if not output then return { ok = false, error = err } end
	local res = {}
	if type(params.fields) == 'table' and #params.fields > 0 then
		for _, k in ipairs(params.fields) do
			local v = output[k]
			if num(v) then res[k] = v elseif type(v) == 'boolean' or type(v) == 'string' then res[k] = v end
		end
	end
	if type(params.match) == 'string' and params.match ~= '' then
		local needle = params.match:lower()
		local count = 0
		for k, v in pairs(output) do
			if type(k) == 'string' and num(v) and k:lower():find(needle, 1, true) then
				res[k] = v
				count = count + 1
				if count >= 80 then break end
			end
		end
		local minion = output.Minion
		if type(minion) == 'table' then
			for k, v in pairs(minion) do
				if type(k) == 'string' and num(v) and ('minion' .. k:lower()):find(needle, 1, true) then res['Minion' .. k] = v end
			end
		end
	end
	return { ok = true, stats = res, mainSkill = mainSkillName(), assumptions = assumptions() }
end

-- Summary -----------------------------------------------------------------------
local function treeSummary()
	local spec = build.spec
	local used, ascUsed = spec:CountAllocNodes()
	local keystones, notables, masteries = {}, {}, {}
	for id, node in pairs(spec.allocNodes) do
		if node.type == 'Keystone' then t_insert(keystones, node.dn or node.name)
		elseif node.type == 'Notable' and not node.ascendancyName then t_insert(notables, node.dn or node.name)
		elseif node.type == 'Mastery' then
			local effect = spec.tree.masteryEffects and spec.tree.masteryEffects[spec.masterySelections[id]]
			t_insert(masteries, (node.dn or node.name) .. ': ' .. (effect and table.concat(effect.sd or {}, ' / ') or '?'))
		end
	end
	table.sort(keystones) table.sort(notables) table.sort(masteries)
	local extra = build.calcsTab.mainOutput and build.calcsTab.mainOutput.ExtraPoints or 0
	local level = tonumber(build.characterLevel) or 1
	return {
		version = spec.treeVersion,
		pointsUsed = used,
		pointsAtLevel = m_min(level - 1, 99) + 23 + extra,
		pointsMax = 99 + 23 + extra,
		ascendancyPointsUsed = ascUsed,
		keystones = keystones, notables = notables, masteries = masteries,
	}
end

handlers.summary = function()
	local output, err = mainOutput()
	if not output then return { ok = false, error = err } end
	local spec = build.spec
	local res = {
		name = build.buildName,
		level = tonumber(build.characterLevel),
		className = spec.curClassName,
		ascendancy = spec.curAscendClassName,
		mainSkill = mainSkillName(),
		tree = treeSummary(),
		assumptions = assumptions(),
	}
	-- Skills
	local skills = Ops.get_skills()
	res.mainSocketGroup = skills and skills.mainSocketGroup
	res.groups = {}
	for _, g in ipairs(skills and skills.groups or {}) do
		local gems = {}
		for _, gem in ipairs(g.gems) do
			if gem.name ~= '' then t_insert(gems, { name = gem.name, level = gem.level, quality = gem.quality, enabled = gem.enabled, support = gem.isSupport }) end
		end
		if #gems > 0 then t_insert(res.groups, { index = g.index, label = g.label ~= '' and g.label or nil, slot = g.slot, enabled = g.enabled ~= false, fullDps = g.includeInFullDPS == true, gems = gems }) end
	end
	-- Items (visible slots only; empty slots listed so they can be filled)
	res.items = {}
	local allocated = spec.allocNodes
	for _, it in ipairs(Ops.get_items() or {}) do
		local show = it.shown ~= false
		local socketNode = tonumber(it.slot:match('^Jewel (%d+)$'))
		if socketNode then show = allocated[socketNode] ~= nil end
		if it.slot:find('Abyssal') and it.id == 0 then show = false end
		if it.slot:find('Swap') and it.id == 0 then show = false end
		if show then
			local item = it.id > 0 and build.itemsTab.items[it.id]
			local mods
			if item then
				mods = {}
				for _, list in ipairs({ item.enchantModLines, item.implicitModLines, item.explicitModLines, item.crucibleModLines }) do
					for _, line in ipairs(list or {}) do
						if line.line and #mods < 16 then t_insert(mods, strip(line.line)) end
					end
				end
			end
			t_insert(res.items, {
				slot = it.slot, id = it.id,
				name = item and strip(item.title or item.name) or nil,
				base = item and item.baseName or nil,
				rarity = item and item.rarity or nil,
				active = it.active,
				mods = mods,
			})
		end
	end
	-- Config: everything that differs from an untouched build
	res.config = {}
	local cfg = Ops.get_config() or {}
	local labels = Ops.get_config_labels() or {}
	for k, v in pairs(cfg) do
		if v ~= false and v ~= '' and v ~= nil then res.config[k] = labels[k] or v end
	end
	-- Tree specs and item sets
	local specs = Ops.list_specs()
	res.specs = specs and specs.specs or nil
	res.activeSpec = specs and specs.activeSpec or nil
	local sets = Ops.list_item_sets()
	res.itemSets = sets and sets.itemSets or nil
	res.activeItemSet = sets and sets.activeItemSetId or nil
	local notes = build.notesTab and build.notesTab.lastContent
	if type(notes) == 'string' and notes ~= '' then res.notes = strip(notes):sub(1, 800) end
	return { ok = true, summary = res }
end

-- Diagnose ----------------------------------------------------------------------
-- One call, in the order AGENTS.md prescribes: resistances, survivability,
-- recovery and mana, damage. Returns numbers plus a list of issues.
local ELEMENTS = { 'Fire', 'Cold', 'Lightning' }
local DAMAGE_TYPES = { 'Physical', 'Fire', 'Cold', 'Lightning', 'Chaos' }

handlers.diagnose = function()
	local o, err = mainOutput()
	if not o then return { ok = false, error = err } end
	local issues = {}
	local function issue(severity, category, message) t_insert(issues, { severity = severity, category = category, message = message }) end
	local level = tonumber(build.characterLevel) or 1
	local res = { level = level, name = build.buildName, mainSkill = mainSkillName(), assumptions = assumptions() }

	-- 1. Resistances
	res.resist = {}
	for _, r in ipairs(ELEMENTS) do
		local v, missing, over = num(o[r .. 'Resist']) or 0, num(o['Missing' .. r .. 'Resist']) or 0, num(o[r .. 'ResistOverCap']) or 0
		local max = v + missing
		res.resist[r] = { value = v, max = max, overCap = over }
		if v < 0 then issue('error', 'resistance', r .. ' resistance is ' .. v .. '% (negative)')
		elseif missing > 0 then issue(v < 60 and 'error' or 'warning', 'resistance', r .. ' resistance ' .. v .. '% is ' .. missing .. '% under the cap (' .. max .. '%)') end
	end
	local chaos = num(o.ChaosResist) or 0
	res.resist.Chaos = { value = chaos, max = chaos + (num(o.MissingChaosResist) or 0), overCap = num(o.ChaosResistOverCap) or 0 }
	if level >= 80 and chaos < -20 then issue('error', 'resistance', 'Chaos resistance is ' .. chaos .. '% at level ' .. level .. '; aim for 0% or more')
	elseif chaos < 0 then issue('warning', 'resistance', 'Chaos resistance is ' .. chaos .. '%') end

	-- 2. Survivability
	res.maxHit = {}
	local weakest, weakestType
	for _, dt in ipairs(DAMAGE_TYPES) do
		local v = num(o[dt .. 'MaximumHitTaken'])
		if v then
			res.maxHit[dt] = m_floor(v)
			if not weakest or v < weakest then weakest, weakestType = v, dt end
		end
	end
	res.weakestHit = weakestType
	res.pool = {
		ehp = num(o.TotalEHP) and m_floor(o.TotalEHP), life = num(o.Life), lifeUnreserved = num(o.LifeUnreserved),
		energyShield = num(o.EnergyShield), ward = num(o.Ward), mana = num(o.Mana),
	}
	res.defence = {
		armour = num(o.Armour), evasion = num(o.Evasion),
		physReduction = num(o.PhysicalDamageReduction),
		evadeChance = num(o.EvadeChance) or num(o.MeleeEvadeChance),
		suppression = num(o.EffectiveSpellSuppressionChance) or num(o.SpellSuppressionChance),
		block = num(o.BlockChance), spellBlock = num(o.SpellBlockChance),
	}
	res.avoid = {}
	for _, a in ipairs({ 'Stun', 'Freeze', 'Chill', 'Shock', 'Ignite', 'Bleed', 'Poison', 'CorruptedBlood' }) do
		local v = num(o[a .. 'AvoidChance'])
		if v and v > 0 then res.avoid[a] = v end
	end
	local life, es = num(o.Life) or 0, num(o.EnergyShield) or 0
	if level >= 70 and life + es < 3000 then issue('warning', 'survivability', 'Small pool for level ' .. level .. ': ' .. life .. ' life + ' .. es .. ' energy shield')
	elseif life < 500 and es < 500 and level > 20 then issue('warning', 'survivability', 'Low pool: ' .. life .. ' life, ' .. es .. ' energy shield') end
	if (num(o.LifeUnreserved) or life) <= 0 then issue('error', 'reservation', 'Unreserved life is 0 or less') end
	local supp = res.defence.suppression or 0
	if supp > 0 and supp < 100 then issue('info', 'defence', 'Spell suppression ' .. supp .. '% is not capped (100%)') end
	if (res.avoid.Freeze or 0) < 100 and level >= 60 then issue('info', 'ailment', 'Not immune to freeze (' .. (res.avoid.Freeze or 0) .. '% avoidance)') end
	if (res.avoid.Stun or 0) < 100 and level >= 80 then issue('info', 'ailment', 'Not immune to stun (' .. (res.avoid.Stun or 0) .. '% avoidance)') end

	-- 3. Recovery and mana
	res.recovery = {
		lifeRegen = num(o.LifeRegenRecovery), netLifeRegen = num(o.NetLifeRegen),
		lifeLeech = num(o.LifeLeechGainRate), lifeOnHit = num(o.LifeOnHitRate),
		esRegen = num(o.EnergyShieldRegenRecovery), esRecharge = num(o.EnergyShieldRecharge),
		esLeech = num(o.EnergyShieldLeechGainRate),
		manaRegen = num(o.ManaRegenRecovery), manaLeech = num(o.ManaLeechGainRate),
	}
	res.mana = { unreserved = num(o.ManaUnreserved), cost = num(o.ManaCost), costPerSecond = num(o.ManaPerSecondCost), lifeCost = num(o.LifeCost) }
	local manaUnreserved = num(o.ManaUnreserved) or 0
	if manaUnreserved < 0 then issue('error', 'reservation', 'Mana is over-reserved by ' .. -manaUnreserved)
	elseif num(o.ManaCost) and o.ManaCost > manaUnreserved then issue('error', 'mana', 'Main skill costs ' .. o.ManaCost .. ' mana but only ' .. manaUnreserved .. ' is unreserved') end
	res.attributes = {}
	for _, a in ipairs({ 'Str', 'Dex', 'Int' }) do
		local have, need = num(o[a]) or 0, num(o['Req' .. a]) or 0
		res.attributes[a] = { value = have, required = need }
		if need > have then issue('error', 'attributes', a .. ' requirement not met: ' .. have .. ' of ' .. need) end
	end

	-- 4. Damage
	res.damage = {
		fullDps = num(o.FullDPS), combinedDps = num(o.CombinedDPS), totalDps = num(o.TotalDPS), dotDps = num(o.TotalDotDPS),
		averageHit = num(o.AverageDamage) or num(o.AverageHit), speed = num(o.Speed),
		hitChance = num(o.HitChance), critChance = num(o.CritChance), critMultiplier = num(o.CritMultiplier),
		bleedDps = num(o.BleedDPS), igniteDps = num(o.IgniteDPS), poisonDps = num(o.TotalPoisonDPS) or num(o.PoisonDPS),
		impaleDps = num(o.ImpaleDPS),
		byType = {},
	}
	for _, dt in ipairs(DAMAGE_TYPES) do
		local v = num(o[dt .. 'StoredCombinedAvg']) or num(o[dt .. 'HitAverage'])
		if v and v > 0 then res.damage.byType[dt] = v end
	end
	local minion = o.Minion
	if type(minion) == 'table' then res.damage.minionDps = num(minion.CombinedDPS) or num(minion.TotalDPS) end
	if dpsOf(o) == 0 and not (res.damage.minionDps and res.damage.minionDps > 0) then
		issue('error', 'damage', 'The main skill deals 0 DPS: no main skill selected, or the gems are not linked')
	end
	if num(o.HitChance) and o.HitChance < 90 then issue('warning', 'damage', 'Hit chance is only ' .. o.HitChance .. '% (accuracy)') end

	-- Gear and tree gaps
	local tree = treeSummary()
	res.points = { used = tree.pointsUsed, available = tree.pointsAtLevel, ascendancyUsed = tree.ascendancyPointsUsed }
	local unspent = tree.pointsAtLevel - tree.pointsUsed
	if unspent >= 5 then issue(unspent >= 15 and 'error' or 'warning', 'tree', unspent .. ' passive points look unspent at level ' .. level .. ' (quest points assumed done)')
	elseif unspent < 0 then issue('warning', 'tree', -unspent .. ' more passive points allocated than level ' .. level .. ' gives') end
	local emptySlots, emptySockets, emptyFlasks = {}, 0, 0
	for _, it in ipairs(Ops.get_items() or {}) do
		if it.id == 0 and it.shown ~= false then
			local socketNode = tonumber(it.slot:match('^Jewel (%d+)$'))
			if socketNode then
				if build.spec.allocNodes[socketNode] then emptySockets = emptySockets + 1 end
			elseif it.slot:match('^Flask') then emptyFlasks = emptyFlasks + 1
			elseif not it.slot:find('Swap') and not it.slot:find('Abyssal') and not it.slot:find('Graft') and it.slot ~= 'Weapon 2' and it.slot ~= 'Ring 3' then
				t_insert(emptySlots, it.slot)
			end
		end
	end
	if #emptySlots > 0 then issue('warning', 'items', 'Empty gear slots: ' .. table.concat(emptySlots, ', ')) end
	if emptySockets > 0 then issue('warning', 'items', emptySockets .. ' allocated jewel socket(s) are empty') end
	if emptyFlasks > 0 then issue(emptyFlasks >= 3 and 'error' or 'warning', 'items', emptyFlasks .. ' of 5 flask slots are empty') end
	res.issues = issues
	return { ok = true, diagnosis = res }
end

-- Edits ----------------------------------------------------------------------
-- One op = one small change. edit applies a list in order; what_if applies,
-- measures and rolls back. Each function returns (result, err).
local function findNode(id)
	local node = build.spec.nodes[tonumber(id)]
	if not node then return nil, 'unknown passive node id ' .. tostring(id) .. ' (use tree_search)' end
	return node
end

local function markChanged(tab)
	if tab then tab.modFlag = true end
	build.buildFlag = true
end

local ops = {}

-- items
ops.equip = function(o)
	if not build.itemsTab.slots[tostring(o.slot)] then return nil, 'unknown slot "' .. tostring(o.slot) .. '" (build_summary lists the slot names)' end
	if o.id then
		local item = build.itemsTab.items[tonumber(o.id)]
		if not item then return nil, 'no item with id ' .. tostring(o.id) .. ' in this build' end
		build.itemsTab.slots[o.slot]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		build.itemsTab:AddUndoState()
		markChanged(build.itemsTab)
		return { slot = o.slot, id = item.id, name = strip(item.title or item.name) }
	end
	local res, err = Ops.add_item_text({ text = o.text, slotName = o.slot, noAutoEquip = true })
	if not res then return nil, err end
	markChanged(build.itemsTab)
	return { slot = o.slot, id = res.id, name = strip(res.name) }
end
ops.unequip = function(o)
	local slot = build.itemsTab.slots[tostring(o.slot)]
	if not slot then return nil, 'unknown slot "' .. tostring(o.slot) .. '"' end
	slot:SetSelItemId(0)
	build.itemsTab:PopulateSlots()
	build.itemsTab:AddUndoState()
	markChanged(build.itemsTab)
	return { slot = o.slot, id = 0 }
end
ops.flask = function(o)
	local ok, err = Ops.set_flask_active({ index = o.index, active = o.active ~= false })
	if not ok then return nil, err end
	markChanged(build.itemsTab)
	return { flask = o.index, active = o.active ~= false }
end
ops.item_set = function(o)
	local res, err = Ops.select_item_set({ id = o.id })
	if not res then return nil, err end
	markChanged(build.itemsTab)
	return res
end

-- skills
local function group(o)
	local g = build.skillsTab.socketGroupList[tonumber(o.group) or 0]
	if not g then return nil, 'no skill group ' .. tostring(o.group) .. ' (build_summary lists them)' end
	return g
end
local function skillsChanged()
	build.skillsTab:AddUndoState()
	markChanged(build.skillsTab)
end
ops.main_skill = function(o)
	local ok, err = Ops.set_main_selection({ mainSocketGroup = o.group, mainActiveSkill = o.skill, skillPart = o.part })
	if not ok then return nil, err end
	markChanged(build)
	build.modFlag = true
	return { mainSocketGroup = build.mainSocketGroup }
end
ops.add_group = function(o)
	local res, err = Ops.create_socket_group({ label = o.label, slot = o.slot, includeInFullDPS = o.full_dps })
	if not res then return nil, err end
	local added = {}
	for _, gem in ipairs(type(o.gems) == 'table' and o.gems or {}) do
		local name = type(gem) == 'table' and gem.name or gem
		local g, gerr = Ops.add_gem({ groupIndex = res.index, gemName = name, level = type(gem) == 'table' and gem.level or nil, quality = type(gem) == 'table' and gem.quality or nil })
		if not g then return nil, 'group ' .. res.index .. ' created, but gem "' .. tostring(name) .. '" failed: ' .. tostring(gerr) end
		t_insert(added, name)
	end
	skillsChanged()
	return { group = res.index, gems = added }
end
ops.remove_group = function(o)
	local ok, err = Ops.remove_skill({ groupIndex = o.group })
	if not ok then return nil, err end
	skillsChanged()
	return { removed = o.group }
end
ops.group_enabled = function(o)
	local res, err = Ops.set_socket_group_enabled({ groupIndex = o.group, enabled = o.enabled ~= false })
	if not res then return nil, err end
	skillsChanged()
	return { group = o.group, enabled = o.enabled ~= false }
end
ops.add_gem = function(o)
	local g, gerr = group(o)
	if not g then return nil, gerr end
	local res, err = Ops.add_gem({ groupIndex = o.group, gemName = o.name, level = o.level, quality = o.quality })
	if not res then return nil, err end
	local gem = g.gemList[res.gemIndex]
	if not gem or not gem.gemData then
		table.remove(g.gemList, res.gemIndex)
		build.skillsTab:ProcessSocketGroup(g)
		recalc()
		return nil, 'unknown gem "' .. tostring(o.name) .. '" (use the exact gem name, e.g. "Lightning Arrow" or "Mirage Archer")'
	end
	skillsChanged()
	return { group = o.group, gem = res.gemIndex, name = res.name }
end
ops.remove_gem = function(o)
	local ok, err = Ops.remove_gem({ groupIndex = o.group, gemIndex = o.gem })
	if not ok then return nil, err end
	skillsChanged()
	return { group = o.group, removed = o.gem }
end
ops.gem = function(o)
	local g, gerr = group(o)
	if not g then return nil, gerr end
	if not g.gemList[tonumber(o.gem) or 0] then return nil, 'no gem ' .. tostring(o.gem) .. ' in group ' .. tostring(o.group) end
	if o.level ~= nil then
		local ok, err = Ops.set_gem_level({ groupIndex = o.group, gemIndex = o.gem, level = o.level })
		if not ok then return nil, err end
	end
	if o.quality ~= nil then
		local ok, err = Ops.set_gem_quality({ groupIndex = o.group, gemIndex = o.gem, quality = o.quality })
		if not ok then return nil, err end
	end
	if o.enabled ~= nil then
		local ok, err = Ops.set_gem_enabled({ groupIndex = o.group, gemIndex = o.gem, enabled = o.enabled == true })
		if not ok then return nil, err end
	end
	skillsChanged()
	local gem = g.gemList[tonumber(o.gem)]
	return { group = o.group, gem = o.gem, name = gem.nameSpec, level = gem.level, quality = gem.quality, enabled = gem.enabled ~= false }
end

-- tree
local function treeChanged()
	build.spec:AddUndoState()
	markChanged(build.spec)
end
ops.alloc = function(o)
	local before = build.spec:CountAllocNodes()
	local added, errors = {}, {}
	for _, id in ipairs(type(o.nodes) == 'table' and o.nodes or { o.node }) do
		local node, err = findNode(id)
		if not node then t_insert(errors, err)
		elseif node.alloc then -- already there
		elseif not node.path then t_insert(errors, (node.dn or tostring(id)) .. ' cannot be reached from the allocated tree')
		elseif node.type == 'Mastery' then t_insert(errors, (node.dn or tostring(id)) .. ' is a mastery: use {op:"mastery", node, effect}')
		elseif not Ops.is_allocatable(node) then t_insert(errors, (node.dn or tostring(id)) .. ' belongs to another class or ascendancy')
		elseif node.ascendancyName and select(2, build.spec:CountAllocNodes()) + (node.pathDist or 1) > 8 then
			t_insert(errors, (node.dn or tostring(id)) .. ' needs more than the 8 ascendancy points a character has; dealloc another ascendancy notable first')
		else
			build.spec:AllocNode(node)
			t_insert(added, node.dn or tostring(id))
		end
	end
	treeChanged()
	recalc()
	local after = build.spec:CountAllocNodes()
	if #added == 0 and #errors > 0 then return nil, table.concat(errors, '; ') end
	return { allocated = added, pointsSpent = after - before, errors = #errors > 0 and errors or nil }
end
ops.dealloc = function(o)
	local before = build.spec:CountAllocNodes()
	local removed, errors = {}, {}
	for _, id in ipairs(type(o.nodes) == 'table' and o.nodes or { o.node }) do
		local node, err = findNode(id)
		if not node then t_insert(errors, err)
		elseif node.alloc then
			if node.type == 'ClassStart' or node.type == 'AscendClassStart' then t_insert(errors, 'cannot remove a class start node')
			else
				build.spec:DeallocNode(node)
				t_insert(removed, node.dn or tostring(id))
			end
		end
	end
	treeChanged()
	recalc()
	local after = build.spec:CountAllocNodes()
	if #removed == 0 and #errors > 0 then return nil, table.concat(errors, '; ') end
	return { removed = removed, pointsFreed = before - after, errors = #errors > 0 and errors or nil }
end
ops.mastery = function(o)
	local node, err = findNode(o.node)
	if not node then return nil, err end
	if node.type ~= 'Mastery' then return nil, (node.dn or tostring(o.node)) .. ' is not a mastery node' end
	local effectId = tonumber(o.effect)
	local valid = false
	for _, e in ipairs(node.masteryEffects or {}) do if e.effect == effectId then valid = true end end
	if not valid then return nil, 'effect ' .. tostring(o.effect) .. ' is not an option of this mastery (tree_search shows the options)' end
	for otherId, otherEffect in pairs(build.spec.masterySelections) do
		if otherEffect == effectId and otherId ~= node.id then return nil, 'that mastery effect is already taken on another mastery node' end
	end
	if not node.alloc and not node.path then return nil, 'mastery cannot be reached: take a notable of its cluster first' end
	-- Same steps as PoB's own mastery popup (TreeTab:SaveMasteryPopup).
	local effect = build.spec.tree.masteryEffects[effectId]
	node.sd = effect.sd
	node.allMasteryOptions = false
	node.reminderText = { 'Tip: Right click to select a different effect' }
	build.spec.tree:ProcessStats(node)
	build.spec.masterySelections[node.id] = effectId
	if not node.alloc then build.spec:AllocNode(node) end
	treeChanged()
	recalc()
	if not build.spec.allocNodes[node.id] then return nil, 'mastery could not be allocated: take a notable of its cluster first' end
	return { mastery = node.dn, effect = effectId }
end
ops.spec = function(o)
	local res, err
	if o.create then
		-- A new spec starts as a copy of the current tree unless told otherwise.
		res, err = Ops.create_spec({ title = tostring(o.create), copyFrom = o.copy_from or build.treeTab.activeSpec, activate = true })
	else
		res, err = Ops.select_spec({ index = o.index })
	end
	if not res then return nil, err end
	markChanged(build.treeTab)
	recalc()
	local active = build.treeTab.activeSpec
	return { activeSpec = active, title = build.spec.title or ('Spec ' .. active), specs = #build.treeTab.specList }
end

-- config
ops.config = function(o)
	local values = {}
	for k, v in pairs(type(o.values) == 'table' and o.values or {}) do values[k] = v end
	local level = values.level
	values.level = nil
	local res = { applied = {}, rejected = {} }
	if next(values) then
		local r, err = Ops.set_config(values)
		if not r then return nil, err end
		res = r
		build.configTab:AddUndoState()
		markChanged(build.configTab)
	end
	if level ~= nil then
		local ok, err = Ops.set_level(level)
		if ok then res.applied.level = tonumber(level) else res.rejected.level = err end
		build.modFlag = true
	end
	if build.configTab.UpdateControls then pcall(build.configTab.UpdateControls, build.configTab) end
	return res
end

local function applyOps(list)
	local results, failed = {}, 0
	for i, o in ipairs(list) do
		local fn = type(o) == 'table' and ops[o.op]
		if not fn then
			results[i] = { ok = false, op = type(o) == 'table' and o.op or nil, error = 'unknown op (valid: equip, unequip, flask, item_set, main_skill, add_group, remove_group, group_enabled, add_gem, remove_gem, gem, alloc, dealloc, mastery, spec, config)' }
			failed = failed + 1
		else
			local okCall, res, err = pcall(fn, o)
			if not okCall then res, err = nil, tostring(res) end
			if res == nil then
				results[i] = { ok = false, op = o.op, error = err or 'failed' }
				failed = failed + 1
			else
				results[i] = { ok = true, op = o.op, result = res }
			end
		end
	end
	return results, failed
end

local KEY_FIELDS = {
	'FullDPS', 'CombinedDPS', 'TotalDPS', 'TotalDotDPS', 'AverageDamage', 'Speed', 'CritChance', 'HitChance',
	'TotalEHP', 'Life', 'LifeUnreserved', 'EnergyShield', 'Mana', 'ManaUnreserved', 'ManaCost',
	'FireResist', 'ColdResist', 'LightningResist', 'ChaosResist',
	'PhysicalMaximumHitTaken', 'FireMaximumHitTaken', 'ColdMaximumHitTaken', 'LightningMaximumHitTaken', 'ChaosMaximumHitTaken',
	'Armour', 'Evasion', 'EffectiveSpellSuppressionChance', 'BlockChance', 'SpellBlockChance',
	'LifeRegenRecovery', 'LifeLeechGainRate', 'EffectiveMovementSpeedMod',
	'Str', 'Dex', 'Int', 'ReqStr', 'ReqDex', 'ReqInt',
}
local function keyStats(extra)
	local o = mainOutput()
	local r = {}
	for _, k in ipairs(KEY_FIELDS) do r[k] = num(o and o[k]) end
	for _, k in ipairs(type(extra) == 'table' and extra or {}) do r[k] = num(o and o[k]) end
	local minion = o and o.Minion
	if type(minion) == 'table' then r.MinionCombinedDPS = num(minion.CombinedDPS) or num(minion.TotalDPS) end
	return r
end
handlers.key_stats = function(params)
	return { ok = true, stats = keyStats(params.fields), mainSkill = mainSkillName(), assumptions = assumptions(),
		name = build.buildName, level = tonumber(build.characterLevel), className = build.spec.curClassName, ascendancy = build.spec.curAscendClassName }
end

-- params: { ops = {...}, fields = {extra stat names} }
handlers.edit = function(params)
	if type(params.ops) ~= 'table' or #params.ops == 0 then return { ok = false, error = 'ops must be a non-empty list' } end
	local before = keyStats(params.fields)
	local results, failed = applyOps(params.ops)
	recalc()
	return { ok = true, results = results, failed = failed, before = before, after = keyStats(params.fields), assumptions = assumptions() }
end

-- Snapshot of everything an op can touch, using PoB's own undo states.
local function capture()
	local b = build
	return {
		activeSpec = b.treeTab.activeSpec,
		specCount = #b.treeTab.specList,
		spec = b.spec:CreateUndoState(),
		items = b.itemsTab:CreateUndoState(),
		skills = b.skillsTab:CreateUndoState(),
		config = b.configTab:CreateUndoState(),
		enemyLevel = b.configTab.enemyLevel,
		level = b.characterLevel,
		levelAuto = b.characterLevelAutoMode,
		flags = {
			build = b.modFlag, spec = b.spec.modFlag, tree = b.treeTab.modFlag, items = b.itemsTab.modFlag,
			skills = b.skillsTab.modFlag, config = b.configTab.modFlag, calcs = b.calcsTab.modFlag,
		},
	}
end
local function restore(s)
	local b = build
	local errors = {}
	local function try(what, fn) local ok, err = pcall(fn) if not ok then t_insert(errors, what .. ': ' .. tostring(err)) end end
	try('spec', function()
		if b.treeTab.activeSpec ~= s.activeSpec then b.treeTab:SetActiveSpec(s.activeSpec) end
		while #b.treeTab.specList > s.specCount do table.remove(b.treeTab.specList) end
		b.spec:RestoreUndoState(s.spec)
	end)
	try('items', function()
		b.itemsTab:RestoreUndoState(s.items)
		-- Undo states keep flask on/off in the item set only; the slot controls need it too.
		for slotName, slot in pairs(b.itemsTab.slots) do
			local entry = b.itemsTab.activeItemSet[slotName]
			if entry and entry.active ~= nil then slot.active = entry.active end
		end
	end)
	try('skills', function() b.skillsTab:RestoreUndoState(s.skills) end)
	try('config', function()
		b.configTab:RestoreUndoState(s.config)
		b.configTab.enemyLevel = s.enemyLevel
		b.configTab:BuildModList()
		-- Building the mod list can write default values back (boss presets do): keep the input exactly as captured.
		local input = b.configTab.input
		for k in pairs(input) do if s.config.input[k] == nil then input[k] = nil end end
		for k, v in pairs(s.config.input) do input[k] = v end
	end)
	b.characterLevel = s.level
	b.characterLevelAutoMode = s.levelAuto
	if b.controls and b.controls.characterLevel then pcall(b.controls.characterLevel.SetText, b.controls.characterLevel, tostring(s.level)) end
	recalc()
	b.modFlag, b.spec.modFlag, b.treeTab.modFlag, b.itemsTab.modFlag = s.flags.build, s.flags.spec, s.flags.tree, s.flags.items
	b.skillsTab.modFlag, b.configTab.modFlag, b.calcsTab.modFlag = s.flags.skills, s.flags.config, s.flags.calcs
	return errors
end

-- params: { ops, keep = bool, fields }
handlers.what_if = function(params)
	if type(params.ops) ~= 'table' or #params.ops == 0 then return { ok = false, error = 'ops must be a non-empty list' } end
	local before = keyStats(params.fields)
	local state = capture()
	local results, failed = applyOps(params.ops)
	recalc()
	local after = keyStats(params.fields)
	local kept = params.keep == true and failed == 0
	local res = { ok = true, results = results, failed = failed, before = before, after = after, kept = kept, assumptions = assumptions() }
	if not kept then
		local errors = restore(state)
		local check = keyStats(params.fields)
		local same = true
		for k, v in pairs(before) do
			local c = check[k]
			if c == nil or math.abs(c - v) > math.max(math.abs(v) * 1e-6, 1e-6) then same = false end
		end
		res.rolledBack = same and #errors == 0
		if not res.rolledBack then res.rollbackProblem = #errors > 0 and table.concat(errors, '; ') or 'stats differ after rolling back' end
	end
	return res
end

-- Tree search -------------------------------------------------------------------
-- params: { query, type?, limit? } -> nodes with stats, path cost, mastery options
handlers.tree_search = function(params)
	local spec = build.spec
	local needle = tostring(params.query or ''):lower()
	local wantType = params.type and tostring(params.type):lower() or nil
	local out = {}
	if wantType ~= 'mastery' then
		local res, err = Ops.search_nodes({ keyword = needle, nodeType = wantType, maxResults = 400 })
		if not res then return { ok = false, error = err } end
		for _, n in ipairs(res.nodes) do
			local node = spec.nodes[n.id]
			if node and node.type ~= 'Mastery' and (node.alloc or Ops.is_allocatable(node)) and not n.isBlighted then
				local entry = { id = n.id, name = n.name, type = n.type, stats = n.stats, allocated = n.allocated or nil, ascendancy = n.ascendancyName }
				if not node.alloc then entry.points = node.pathDist ~= 1000 and node.pathDist or nil end
				t_insert(out, entry)
			end
		end
	end
	if not wantType or wantType == 'mastery' then
		-- Masteries match on their name or on any of their effects.
		for id, node in pairs(spec.nodes) do
			if node.type == 'Mastery' and node.masteryEffects then
				local hit = (node.dn or node.name or ''):lower():find(needle, 1, true) ~= nil
				local effects = {}
				for _, e in ipairs(node.masteryEffects) do
					local effect = spec.tree.masteryEffects[e.effect]
					local sd = effect and effect.sd or e.stats or {}
					for _, line in ipairs(sd) do if line:lower():find(needle, 1, true) then hit = true end end
					t_insert(effects, { id = e.effect, stats = sd, selected = spec.masterySelections[id] == e.effect or nil })
				end
				if hit then
					local entry = { id = id, name = node.dn or node.name, type = 'mastery', effects = effects, allocated = node.alloc or nil }
					if not node.alloc then entry.points = node.path and node.pathDist ~= 1000 and node.pathDist or nil end
					t_insert(out, entry)
				end
			end
		end
	end
	table.sort(out, function(a, b)
		local pa, pb = a.allocated and 0 or (a.points or 999), b.allocated and 0 or (b.points or 999)
		if pa ~= pb then return pa < pb end
		return a.name < b.name
	end)
	local limit = m_min(m_max(tonumber(params.limit) or 15, 1), 50)
	local total = #out
	while #out > limit do table.remove(out) end
	return { ok = true, nodes = out, total = total }
end

-- Passive suggestions -----------------------------------------------------------
-- params: { max_points = 5, focus = "balanced"|"dps"|"defence", limit = 10 }
-- Simulates each nearby notable/keystone (with its path) and each mastery effect.
handlers.suggest_passives = function(params)
	local spec = build.spec
	local maxPoints = m_min(m_max(tonumber(params.max_points) or 5, 1), 10)
	local focus = params.focus or 'balanced'
	local calc = build.calcsTab:GetMiscCalculator()
	local okBase, base = pcall(calc, {})
	if not okBase then return { ok = false, error = 'base calculation failed: ' .. tostring(base) } end
	local baseDps, baseEhp, baseLife = dpsOf(base), num(base.TotalEHP) or 0, num(base.Life) or 0
	local function score(o)
		local d, e = pctChange(dpsOf(o), baseDps), pctChange(num(o.TotalEHP) or 0, baseEhp)
		local s = focus == 'dps' and d or (focus == 'defence' and e or (d + 0.6 * e))
		return s, d, e
	end
	local candidates, evaluated = {}, 0
	local ascendancyUsed = select(2, spec:CountAllocNodes())
	local function consider(node, pathNodes, points, name, stats, extra)
		if evaluated >= 250 then return end
		local okCalc, o = pcall(calc, { addNodes = pathNodes })
		evaluated = evaluated + 1
		if not okCalc or type(o) ~= 'table' then return end
		local s, d, e = score(o)
		if s > 0.05 then
			local c = { id = node.id, name = name, type = node.type, points = points, dpsPct = d, ehpPct = e,
				lifeDelta = (num(o.Life) or 0) - baseLife, score = s, value = s / m_max(points, 1), stats = stats }
			for k, v in pairs(extra or {}) do c[k] = v end
			t_insert(candidates, c)
		end
	end
	for id, node in pairs(spec.nodes) do
		if not node.alloc and node.path and node.pathDist and node.pathDist <= maxPoints and Ops.is_allocatable(node) and node.modKey ~= ''
			and not (node.ascendancyName and ascendancyUsed + node.pathDist > 8) then
			if node.type == 'Notable' or node.type == 'Keystone' or (node.type == 'Normal' and (node.pathDist == 1 or node.ascendancyName)) then
				local pathNodes = {}
				for _, p in ipairs(node.path) do pathNodes[p] = true end
				consider(node, pathNodes, node.pathDist, node.dn or node.name, node.sd)
			end
		end
		if node.type == 'Mastery' and node.masteryEffects and node.path and (node.alloc or (node.pathDist or 99) <= maxPoints) then
			local current = spec.masterySelections[id]
			for _, e in ipairs(node.masteryEffects) do
				local taken = false
				for otherId, effectId in pairs(spec.masterySelections) do if effectId == e.effect then taken = true end end
				local effect = spec.tree.masteryEffects[e.effect]
				if effect and not taken and not node.alloc then
					local effectNode = { id = node.id, type = node.type, name = node.name, sd = {} }
					for i, sd in ipairs(effect.sd or {}) do effectNode.sd[i] = sd end
					spec.tree:ProcessStats(effectNode)
					if effectNode.modKey ~= '' then
						local pathNodes = { [effectNode] = true }
						for _, p in ipairs(node.path) do if p ~= node then pathNodes[p] = true end end
						consider(node, pathNodes, node.pathDist, (node.dn or node.name), effect.sd, { effect = e.effect })
					end
				end
			end
		end
	end
	table.sort(candidates, function(a, b) if a.value ~= b.value then return a.value > b.value end return a.score > b.score end)
	local limit = m_min(m_max(tonumber(params.limit) or 10, 1), 30)
	while #candidates > limit do table.remove(candidates) end
	local tree = treeSummary()
	return { ok = true, suggestions = candidates, evaluated = evaluated, focus = focus, maxPoints = maxPoints,
		pointsFree = tree.pointsAtLevel - tree.pointsUsed, assumptions = assumptions() }
end

-- Anoint: wraps Core's native simulation and adds percentages.
local evaluateAnoints = handlers.evaluate_anoint_candidates
handlers.anoint = function(params)
	local res = evaluateAnoints({ slot = params.slot or 'Amulet', focus = params.focus == 'balanced' and 'both' or params.focus, limit = params.limit or 10 })
	if res.ok then res.assumptions = assumptions() end
	return res
end

-- Affixes ---------------------------------------------------------------------
-- params: { query = "maximum life", item = "ring"?, type = "Prefix"|"Suffix"?, bench = bool?, limit? }
-- Searches PoB's own mod tables: rollable tiers (ModExplicit) or crafting-bench mods (ModMaster).
handlers.affixes = function(params)
	local needle = tostring(params.query or ''):lower()
	if needle == '' then return { ok = false, error = 'query is required, e.g. "maximum life"' } end
	local itemFilter = params.item and tostring(params.item):lower() or nil
	local typeFilter = params.type and tostring(params.type):lower() or nil
	local function lines(mod)
		local l = {}
		for _, s in ipairs(mod) do t_insert(l, s) end
		return l
	end
	local function matches(mod)
		if typeFilter and tostring(mod.type):lower() ~= typeFilter then return false end
		for _, s in ipairs(mod) do if s:lower():find(needle, 1, true) then return true end end
		return false
	end
	local out = {}
	if params.bench then
		for _, mod in ipairs(data.masterMods or {}) do
			if matches(mod) then
				local classes, fits = {}, itemFilter == nil
				for class in pairs(mod.types or {}) do
					t_insert(classes, class)
					if itemFilter and class:lower():find(itemFilter, 1, true) then fits = true end
				end
				table.sort(classes)
				if fits then t_insert(out, { type = mod.type, name = mod.affix, stats = lines(mod), level = mod.level, group = mod.group, items = classes }) end
			end
		end
		table.sort(out, function(a, b) if a.group ~= b.group then return a.group < b.group end return a.level > b.level end)
	else
		for id, mod in pairs(data.itemMods.Item or {}) do
			if (mod.type == 'Prefix' or mod.type == 'Suffix') and matches(mod) then
				-- weightKey is checked in order in game: the first tag the base has decides.
				local tags, fits, decided = {}, itemFilter == nil, false
				for i, key in ipairs(mod.weightKey or {}) do
					local weight = mod.weightVal[i] or 0
					if weight > 0 then t_insert(tags, key == 'default' and 'all other items' or key) end
					if itemFilter and not decided and (key == itemFilter or key == 'default') then
						decided = true
						fits = weight > 0
					end
				end
				if fits and #tags > 0 then t_insert(out, { type = mod.type, name = mod.affix, stats = lines(mod), level = mod.level, group = mod.group, items = tags }) end
			end
		end
		table.sort(out, function(a, b) if a.group ~= b.group then return a.group < b.group end return a.level > b.level end)
	end
	local total = #out
	local limit = m_min(m_max(tonumber(params.limit) or 20, 1), 60)
	while #out > limit do table.remove(out) end
	return { ok = true, mods = out, total = total, source = params.bench and 'crafting bench (PoB ModMaster)' or 'rollable affixes (PoB ModExplicit)' }
end

-- Notes ---------------------------------------------------------------------------
handlers.gem_names = function(params)
	-- Close matches for a gem name the AI got slightly wrong.
	local needle = tostring(params.query or ''):lower()
	local out = {}
	for _, gemData in pairs(build.data.gems or {}) do
		if gemData.name and gemData.name:lower():find(needle, 1, true) then
			t_insert(out, gemData.name)
			if #out >= 15 then break end
		end
	end
	table.sort(out)
	return { ok = true, names = out }
end

-- Config search: which options exist, so the AI can set them by name.
-- params: { query }
handlers.config_search = function(params)
	local needle = tostring(params.query or ''):lower()
	local okLoad, varList = pcall(LoadModule, 'Modules/ConfigOptions')
	if not okLoad or type(varList) ~= 'table' then return { ok = false, error = 'could not load PoB config options' } end
	local input = build.configTab.input or {}
	local out = {}
	for _, var in ipairs(varList) do
		if var.var and var.label then
			local label = strip(var.label)
			if needle == '' or var.var:lower():find(needle, 1, true) or label:lower():find(needle, 1, true) then
				local entry = { key = var.var, label = label, type = var.type, value = input[var.var] }
				if var.type == 'list' and type(var.list) == 'table' then
					entry.options = {}
					for _, e in ipairs(var.list) do t_insert(entry.options, tostring(e.val)) end
				end
				t_insert(out, entry)
				if #out >= 25 then break end
			end
		end
	end
	return { ok = true, options = out }
end

-- Support gems, boss check, jewels, item affixes, notes
loadfile(DIR .. 'Advice.lua')(handlers, Ops, {
	num = num, dpsOf = dpsOf, pctChange = pctChange, strip = strip, recalc = recalc, mainOutput = mainOutput,
	assumptions = assumptions, mainSkillName = mainSkillName, capture = capture, restore = restore,
})

-- Character import and progress tracking (Stage 2)
loadfile(DIR .. 'Character.lua')(handlers, Ops, {
	keyStats = keyStats, mainSkillName = mainSkillName, assumptions = assumptions, mainOutput = mainOutput,
})
