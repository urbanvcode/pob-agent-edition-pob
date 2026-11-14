-- Agent Edition economy (Stage 5): what the player owns and what to look for.
-- Loaded by Tools.lua with (handlers, Ops, shared). Read-only: nothing here
-- changes the build. Prices and purchases are done by agent-mcp (poe.ninja and
-- instant-buyout trade searches); combined sets are simulated with what_if.
local handlers, Ops, shared = ...

local t_insert, t_sort = table.insert, table.sort
local m_floor = math.floor
local strip = shared.strip
local dkjson = require('dkjson')

-- The biggest linked socket group of an item (5L / 6L matter for prices).
local function maxLinks(item)
	local groups, best = {}, 0
	for _, s in ipairs(item.sockets or {}) do
		groups[s.group] = (groups[s.group] or 0) + 1
		if groups[s.group] > best then best = groups[s.group] end
	end
	return best
end

-- Every item in the build: where it is equipped (active set), whether another
-- item set uses it, and the gems in socket groups. params: {}
handlers.economy_items = function()
	if not build or not build.itemsTab then return { ok = false, error = 'build not initialized' } end
	local itemsTab = build.itemsTab
	local equipped, otherSet = {}, {}
	for slotName, slot in pairs(itemsTab.slots) do
		local id = slot.selItemId
		if id and id > 0 and slot:IsShown() ~= false then equipped[id] = slotName end
	end
	for setId, set in pairs(itemsTab.itemSets or {}) do
		if set ~= itemsTab.activeItemSet then
			for _, entry in pairs(set) do
				if type(entry) == 'table' and entry.selItemId and entry.selItemId > 0 then otherSet[entry.selItemId] = true end
			end
		end
	end
	local items = {}
	for id, item in pairs(itemsTab.items) do
		t_insert(items, {
			id = id, name = strip(item.title or item.name or ''), baseName = item.baseName, rarity = item.rarity, type = item.type,
			corrupted = item.corrupted == true, links = maxLinks(item), slot = equipped[id], otherSet = otherSet[id] or nil,
		})
	end
	t_sort(items, function(a, b) return a.id < b.id end)
	local gems = {}
	for gi, group in ipairs(build.skillsTab and build.skillsTab.socketGroupList or {}) do
		for _, gem in ipairs(group.gemList or {}) do
			local name = gem.grantedEffect and gem.grantedEffect.name or gem.nameSpec
			if name and name ~= '' then
				t_insert(gems, {
					name = name, level = tonumber(gem.level) or 1, quality = tonumber(gem.quality) or 0,
					support = gem.grantedEffect and gem.grantedEffect.support == true or false,
					enabled = gem.enabled ~= false and group.enabled ~= false, group = gi, slot = group.slot,
				})
			end
		end
	end
	return { ok = true, result = { items = items, gems = gems } }
end

-- Trade stat id -> readable text and roll range per item class, from PoB's
-- own query data (offline). Only normal explicit and implicit mods count for
-- the ranges: corruptions, eldritch and enchants are not what SSF loot rolls.
local statInfo, explicitByText
local function loadStats()
	if statInfo then return end
	statInfo, explicitByText = {}, {}
	local ok, data = pcall(LoadModule, 'Data/QueryMods.lua')
	if not ok or type(data) ~= 'table' then return end
	for groupName, group in pairs(data) do
		for _, mod in pairs(group) do
			local tm = type(mod) == 'table' and mod.tradeMod
			if tm and tm.id and tm.text then
				local info = statInfo[tm.id]
				if not info then info = { text = tm.text, max = {} } statInfo[tm.id] = info end
				if groupName == 'Explicit' or groupName == 'Implicit' then
					for k, v in pairs(mod) do
						if type(v) == 'table' and v.max and k ~= 'tradeMod' then
							info.max[k] = math.max(info.max[k] or -math.huge, tonumber(v.max) or 0)
						end
					end
					if groupName == 'Explicit' and not explicitByText[tm.text] then explicitByText[tm.text] = info end
				end
			end
		end
	end
end

-- Trade category -> QueryMods item class.
local CLASS = {
	['accessory.ring'] = 'Ring', ['accessory.amulet'] = 'Amulet', ['accessory.belt'] = 'Belt', ['armour.helmet'] = 'Helmet',
	['armour.gloves'] = 'Gloves', ['armour.boots'] = 'Boots', ['armour.chest'] = 'Chest', ['armour.shield'] = 'Shield',
	['armour.quiver'] = 'Quiver', ['weapon.wand'] = 'Wand', ['weapon.dagger'] = 'Dagger', ['weapon.claw'] = 'Claw',
	['weapon.bow'] = 'Bow', ['weapon.staff'] = 'Staff', ['weapon.sceptre'] = 'Sceptre', ['weapon.onesword'] = '1HSword',
	['weapon.twosword'] = '2HSword', ['weapon.oneaxe'] = '1HAxe', ['weapon.twoaxe'] = '2HAxe', ['weapon.onemace'] = '1HMace',
	['weapon.twomace'] = '2HMace', ['jewel'] = 'BaseJewel', ['jewel.abyss'] = 'AbyssJewel',
}
-- Pseudo totals take their range from the matching single explicit mod.
local PSEUDO = {
	['pseudo.pseudo_total_fire_resistance'] = '+#% to Fire Resistance', ['pseudo.pseudo_total_cold_resistance'] = '+#% to Cold Resistance',
	['pseudo.pseudo_total_lightning_resistance'] = '+#% to Lightning Resistance', ['pseudo.pseudo_total_chaos_resistance'] = '+#% to Chaos Resistance',
	['pseudo.pseudo_total_life'] = '+# to maximum Life', ['pseudo.pseudo_total_energy_shield'] = '+# to maximum Energy Shield',
	['pseudo.pseudo_total_mana'] = '+# to maximum Mana', ['pseudo.pseudo_total_strength'] = '+# to Strength',
	['pseudo.pseudo_total_dexterity'] = '+# to Dexterity', ['pseudo.pseudo_total_intelligence'] = '+# to Intelligence',
}

local function describe(id, class)
	loadStats()
	local info = statInfo[id]
	local text = info and info.text
	local max = info and class and info.max[class]
	if PSEUDO[id] then
		local single = explicitByText[PSEUDO[id]]
		text = PSEUDO[id]:gsub(' to ', ' total to ', 1)
		max = single and class and single.max[class]
	end
	text = text or tostring(id):gsub('^pseudo%.pseudo_', ''):gsub('_', ' ')
	return text, (max and max > -math.huge) and max or nil
end

local function weightsFor(focus)
	if focus == 'dps' then return { { label = 'Full DPS', stat = 'FullDPS', weightMult = 1.0 } } end
	if focus == 'defence' then return { { label = 'Effective Hit Pool', stat = 'TotalEHP', weightMult = 1.0 } } end
	return { { label = 'Full DPS', stat = 'FullDPS', weightMult = 1.0 }, { label = 'Effective Hit Pool', stat = 'TotalEHP', weightMult = 0.5 } }
end

-- What a rare for each slot should carry, from PoB's weighted best-upgrade
-- query (the same one plan_upgrades sends to trade): the stats that help this
-- build most, their relative value, and how much of each alone would already
-- beat the current item ("good enough" thresholds for SSF and loot filters).
-- params: { slots = {...}, focus = 'balanced'|'dps'|'defence', top = 6 }
handlers.economy_targets = function(params)
	if not build or not build.itemsTab then return { ok = false, error = 'build not initialized' } end
	local top = math.min(math.max(tonumber(params.top) or 6, 1), 12)
	local out = {}
	for _, slotName in ipairs(type(params.slots) == 'table' and params.slots or {}) do
		local entry = { slot = slotName }
		local slot = build.itemsTab.slots[slotName]
		local current = slot and slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId] or nil
		entry.current = current and strip(current.title or current.name or '') or nil
		entry.currentRarity = current and current.rarity or nil
		local res = slot and handlers.generate_weighted_trade_query({ slot = slotName, options = { statWeights = weightsFor(params.focus) } })
		if not res or not res.ok then
			entry.error = res and res.error or ('unknown slot: ' .. tostring(slotName))
		else
			local q = res.query
			if type(q) == 'string' then q = dkjson.decode(q) end
			local group = q and q.query and q.query.stats and q.query.stats[1]
			local minWeight = group and group.value and tonumber(group.value.min) or 0
			local class = q and q.query and q.query.filters and q.query.filters.type_filters
				and q.query.filters.type_filters.filters and q.query.filters.type_filters.filters.category
				and CLASS[q.query.filters.type_filters.filters.category.option] or nil
			-- One line per stat text: the explicit roll wins over the same text as an implicit.
			local stats, byText = {}, {}
			for _, f in ipairs(group and group.filters or {}) do
				local w = f.value and tonumber(f.value.weight)
				local kind = tostring(f.id):match('^(%a+)%.') or ''
				if w and w > 0 and (kind == 'explicit' or kind == 'implicit' or kind == 'pseudo') then
					local text, max = describe(f.id, class)
					-- A stat that cannot roll on this item class is not a loot target.
					if max or kind == 'pseudo' then
						if kind == 'implicit' then text = text .. ' (implicit)' end
						local key = text:gsub(' %(implicit%)$', '')
						local seen = byText[key]
						if not seen then
							seen = { id = f.id, text = text, weight = w, max = max }
							byText[key] = seen
							t_insert(stats, seen)
						elseif kind == 'explicit' or w * (max or 0) > seen.weight * (seen.max or 0) then
							seen.id, seen.text, seen.weight, seen.max = f.id, text, w, max
						end
					end
				end
			end
			-- Ranked by what a top roll is worth (weight x highest roll); without a known range, by weight alone.
			for _, st in ipairs(stats) do st.worth = st.weight * (st.max or (minWeight > 0 and minWeight / st.weight) or 1) end
			t_sort(stats, function(a, b) return a.worth > b.worth end)
			local topWorth = stats[1] and stats[1].worth or 1
			local list = {}
			for i = 1, math.min(top, #stats) do
				local st = stats[i]
				local alone = minWeight > 0 and minWeight / st.weight or nil
				if alone then alone = alone >= 10 and m_floor(alone + 0.5) or m_floor(alone * 10 + 0.5) / 10 end
				-- worth: the build's relative gain of a top roll x1000, comparable across slots (slot ordering).
				t_insert(list, { text = st.text, id = st.id, value = m_floor(st.worth / topWorth * 100 + 0.5), max = st.max, worth = st.worth,
					-- How much alone beats the current item; only when one roll can reach it.
					alone = alone and (not st.max or alone <= st.max) and alone or nil })
			end
			entry.stats = list
			entry.category = q and q.query and q.query.filters and q.query.filters.type_filters
				and q.query.filters.type_filters.filters and q.query.filters.type_filters.filters.category
				and q.query.filters.type_filters.filters.category.option or nil
			entry.minWeight = minWeight
		end
		t_insert(out, entry)
	end
	return { ok = true, result = out }
end
