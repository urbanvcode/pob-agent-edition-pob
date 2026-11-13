-- Agent Edition "Create a build" (Stage 11): what the AI needs from PoB to
-- turn a template into a new build and to make "close enough" item targets.
-- Loaded by Tools.lua with (handlers, Ops, shared). Read-only: every
-- simulation uses PoB's misc calculator (test_items); the build is not changed.
local handlers, Ops, shared = ...

local t_insert = table.insert
local strip = shared.strip

local TARGET_SLOTS = { 'Weapon 1', 'Weapon 2', 'Helmet', 'Body Armour', 'Gloves', 'Boots', 'Amulet', 'Ring 1', 'Ring 2', 'Belt' }
local MAX_LINES = 10

-- Item type -> trade site category.
local CATEGORY = {
	['Helmet'] = 'armour.helmet', ['Gloves'] = 'armour.gloves', ['Boots'] = 'armour.boots', ['Body Armour'] = 'armour.chest',
	['Shield'] = 'armour.shield', ['Quiver'] = 'armour.quiver', ['Ring'] = 'accessory.ring', ['Amulet'] = 'accessory.amulet',
	['Belt'] = 'accessory.belt', ['Bow'] = 'weapon.bow', ['Wand'] = 'weapon.wand', ['Dagger'] = 'weapon.dagger',
	['Rune Dagger'] = 'weapon.runedagger', ['Claw'] = 'weapon.claw', ['Staff'] = 'weapon.staff', ['Warstaff'] = 'weapon.warstaff',
	['Sceptre'] = 'weapon.sceptre', ['One Handed Sword'] = 'weapon.onesword', ['Thrusting One Handed Sword'] = 'weapon.onesword',
	['Two Handed Sword'] = 'weapon.twosword', ['One Handed Axe'] = 'weapon.oneaxe', ['Two Handed Axe'] = 'weapon.twoaxe',
	['One Handed Mace'] = 'weapon.onemace', ['Two Handed Mace'] = 'weapon.twomace', ['Jewel'] = 'jewel', ['Abyss Jewel'] = 'jewel.abyss',
}

-- Mod text template ("+# to maximum Life") -> trade stat id, from PoB's own query data (offline).
local tradeIds
local function tradeIdFor(text)
	if not tradeIds then
		tradeIds = {}
		local ok, data = pcall(LoadModule, 'Data/QueryMods.lua')
		if ok and type(data) == 'table' then
			for _, groupName in ipairs({ 'Explicit', 'Implicit' }) do
				for _, mod in pairs(data[groupName] or {}) do
					local tm = type(mod) == 'table' and mod.tradeMod
					if tm and tm.id and tm.text and not tradeIds[tm.text] then tradeIds[tm.text] = tm.id end
				end
			end
		end
	end
	local template = text:gsub('%d+%.?%d*', '#')
	return tradeIds[template] or tradeIds[template:gsub('^%+', '')]
end

local RANGE = '%(%-?[%d%.]+%-%-?[%d%.]+%)'

local function rolled(modLine)
	local ok, line = pcall(itemLib.applyRange, modLine.line, modLine.range or main.defaultItemAffixQuality or 0.5, modLine.valueScalar)
	return strip(ok and line or modLine.line)
end

local function equipped(slotName)
	local slot = build.itemsTab.slots[slotName]
	local id = slot and slot.selItemId
	return id and id > 0 and build.itemsTab.items[id] or nil
end

-- One copy of the item with a change applied to its mod lines, as item text.
local function variant(item, change)
	local okNew, copy = pcall(new, 'Item', item:BuildRaw())
	if not okNew or not copy then return nil end
	change(copy)
	local okRaw, raw = pcall(copy.BuildRaw, copy)
	return okRaw and raw or nil
end

-- Every rare/magic item becomes a target: the value of each mod line (the
-- build simulated without it), the item as it is and a plain base without
-- mods as the baseline. Uniques: each ranged line at its lowest and highest
-- roll. params: { slots = {...} } (default: weapons, armour, jewellery)
handlers.create_targets = function(params)
	if not build or not build.itemsTab or not build.calcsTab then return { ok = false, error = 'build not initialized' } end
	local out = {}
	for _, slotName in ipairs(type(params.slots) == 'table' and #params.slots > 0 and params.slots or TARGET_SLOTS) do
		local item = build.itemsTab.slots[slotName] and equipped(slotName)
		if item and (item.rarity == 'RARE' or item.rarity == 'MAGIC') then
			local entry = { slot = slotName, kind = 'rare', name = strip(item.title or item.name or ''), baseName = item.baseName,
				category = CATEGORY[item.type], ilvl = item.itemLevel, lines = {} }
			local texts = { 'Rarity: NORMAL\n' .. tostring(item.baseName) }
			for _, listName in ipairs({ 'implicitModLines', 'explicitModLines' }) do
				for i, ml in ipairs(item[listName] or {}) do
					if #entry.lines >= MAX_LINES then break end
					local raw = variant(item, function(copy) table.remove(copy[listName], i) end)
					if raw then
						local text = rolled(ml)
						t_insert(entry.lines, { text = text, implicit = listName == 'implicitModLines' or nil, crafted = ml.crafted or nil,
							unsupported = ml.extra and true or nil, tradeId = tradeIdFor(text) })
						t_insert(texts, raw)
					end
				end
			end
			local res = handlers.test_items({ slot = slotName, items = texts })
			if not res.ok then
				entry.error = res.error
			else
				entry.target = res.result.base
				entry.plain = res.result.results[1].ok and res.result.results[1].stats or nil
				for i, line in ipairs(entry.lines) do
					local r = res.result.results[i + 1]
					line.without = r and r.ok and r.stats or nil
				end
				entry.itemText = item:BuildRaw()
			end
			t_insert(out, entry)
		elseif item and item.rarity == 'UNIQUE' then
			local entry = { slot = slotName, kind = 'unique', name = strip(item.title or item.name or ''), baseName = item.baseName, lines = {} }
			local texts = {}
			for i, ml in ipairs(item.explicitModLines or {}) do
				if #entry.lines >= MAX_LINES then break end
				if ml.line and ml.line:match(RANGE) and not ml.extra then
					local low = variant(item, function(copy) copy.explicitModLines[i].range = 0 end)
					local high = variant(item, function(copy) copy.explicitModLines[i].range = 1 end)
					if low and high then
						local okL, lowText = pcall(itemLib.applyRange, ml.line, 0, ml.valueScalar)
						local okH, highText = pcall(itemLib.applyRange, ml.line, 1, ml.valueScalar)
						t_insert(entry.lines, { text = strip(ml.line), now = rolled(ml), range = ml.range,
							low = okL and strip(lowText) or nil, high = okH and strip(highText) or nil })
						t_insert(texts, low)
						t_insert(texts, high)
					end
				end
			end
			if #texts > 0 then
				local res = handlers.test_items({ slot = slotName, items = texts })
				if res.ok then
					entry.now = res.result.base
					for i, line in ipairs(entry.lines) do
						local lo, hi = res.result.results[2 * i - 1], res.result.results[2 * i]
						line.lowStats = lo and lo.ok and lo.stats or nil
						line.highStats = hi and hi.ok and hi.stats or nil
					end
				else
					entry.error = res.error
				end
			end
			t_insert(out, entry)
		end
	end
	return { ok = true, result = out }
end

-- Items per item set (the build's stages / budgets) for the cost per stage. params: {}
handlers.create_sets = function()
	if not build or not build.itemsTab then return { ok = false, error = 'build not initialized' } end
	local itemsTab = build.itemsTab
	local sets = {}
	for _, setId in ipairs(itemsTab.itemSetOrderList or {}) do
		local set = itemsTab.itemSets[setId]
		if set then
			local entry = { id = setId, title = set.title or ('Item Set ' .. setId), active = setId == itemsTab.activeItemSetId or nil, items = {} }
			for slotName, slotEntry in pairs(set) do
				local id = type(slotEntry) == 'table' and slotEntry.selItemId
				local item = id and id > 0 and itemsTab.items[id]
				if item and not slotName:match('^Swap') then
					local links, groups = 0, {}
					for _, s in ipairs(item.sockets or {}) do
						groups[s.group] = (groups[s.group] or 0) + 1
						if groups[s.group] > links then links = groups[s.group] end
					end
					t_insert(entry.items, { id = id, slot = slotName, name = strip(item.title or item.name or ''), baseName = item.baseName,
						rarity = item.rarity, type = item.type, links = links, corrupted = item.corrupted == true })
				end
			end
			table.sort(entry.items, function(a, b) return a.slot < b.slot end)
			t_insert(sets, entry)
		end
	end
	return { ok = true, result = sets }
end

-- What PoB does not model in this build: item lines it cannot read, passives
-- it cannot parse and gems without calculations. params: {}
handlers.create_unmodelled = function()
	if not build or not build.itemsTab then return { ok = false, error = 'build not initialized' } end
	local items, nodes, gems = {}, {}, {}
	local seen = {}
	for slotName, slot in pairs(build.itemsTab.slots) do
		local item = slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId]
		if item and not seen[item] and slot:IsShown() ~= false then
			seen[item] = true
			for _, listName in ipairs({ 'enchantModLines', 'implicitModLines', 'explicitModLines' }) do
				for _, ml in ipairs(item[listName] or {}) do
					if ml.extra then t_insert(items, { slot = slotName, item = strip(item.title or item.name or ''), line = strip(ml.line) }) end
				end
			end
		end
	end
	for _, node in pairs(build.spec and build.spec.allocNodes or {}) do
		if node.unknown or node.extra then
			t_insert(nodes, { name = node.dn or node.name, partly = node.extra and not node.unknown or nil, stats = node.sd })
		end
	end
	for _, group in ipairs(build.skillsTab and build.skillsTab.socketGroupList or {}) do
		for _, gem in ipairs(group.gemList or {}) do
			if gem.nameSpec and gem.nameSpec ~= '' and (not gem.gemData or (gem.gemData.grantedEffect and gem.gemData.grantedEffect.unsupported)) then
				t_insert(gems, { name = gem.nameSpec, missing = not gem.gemData or nil })
			end
		end
	end
	return { ok = true, result = { items = items, nodes = nodes, gems = gems } }
end

-- Playstyle of skill gems from PoB's gem data (tags and skill types).
-- params: { names = {...} } -> { [name] = { styles = {...}, support = bool } }
local function stylesOf(gemData)
	local tags = gemData.tags or {}
	local types = gemData.grantedEffect and gemData.grantedEffect.skillTypes or {}
	local function st(name) return SkillType and SkillType[name] and types[SkillType[name]] end
	local styles = {}
	if tags.melee then t_insert(styles, 'melee') end
	if tags.bow or (tags.attack and tags.projectile and not tags.melee) then t_insert(styles, 'ranged') end
	if tags.spell then t_insert(styles, 'spells') end
	if tags.minion then t_insert(styles, 'minions') end
	if tags.totem then t_insert(styles, 'totems') end
	if tags.trap then t_insert(styles, 'traps') end
	if tags.mine then t_insert(styles, 'mines') end
	local dot = st('DamageOverTime') or st('DegenOnlySpellDamage')
	if dot then t_insert(styles, 'dot') end
	if (tags.attack or tags.spell) and not tags.minion and not st('DegenOnlySpellDamage') then t_insert(styles, 'hits') end
	return styles
end

handlers.create_gem_tags = function(params)
	local want = {}
	for _, name in ipairs(type(params.names) == 'table' and params.names or {}) do want[tostring(name):lower()] = tostring(name) end
	local out = {}
	for _, gemData in pairs(build and build.data and build.data.gems or data.gems or {}) do
		local name = gemData.name
		local key = name and (want[name:lower()] or want[(name .. ' Support'):lower()])
		if key and not out[key] then
			local support = gemData.grantedEffect and gemData.grantedEffect.support == true or false
			out[key] = { styles = stylesOf(gemData), support = support, transfigured = gemData.grantedEffect and gemData.grantedEffect.name ~= gemData.name or nil }
		end
	end
	return { ok = true, result = out }
end

-- Gem and unique names PoB knows that a text names (patch-note lines for the
-- theorycraft mode). params: { texts = {...} } -> { gems = {...}, uniques = {...} }
local knownNames
local function phraseIn(text, name)
	local s, e = text:find(name, 1, true)
	while s do
		local before, after = text:sub(s - 1, s - 1), text:sub(e + 1, e + 1)
		-- "Frenzy" the gem, not "Frenzy Charges"
		if not before:match('[%w]') and not after:match('[%w]') and not text:sub(e + 1, e + 8):match('^ Charge') then return true end
		s, e = text:find(name, e + 1, true)
	end
	return false
end
handlers.create_find_names = function(params)
	if not knownNames then
		knownNames = { gems = {}, uniques = {} }
		local seen = {}
		for _, gemData in pairs(build and build.data and build.data.gems or data.gems or {}) do
			if gemData.name and #gemData.name >= 4 and not seen[gemData.name] then seen[gemData.name] = true t_insert(knownNames.gems, gemData.name) end
		end
		local db = main and main.uniqueDB and main.uniqueDB.list or {}
		for _, item in pairs(db) do
			local name = item.title or item.name
			if name and #name >= 4 and not seen[name] then seen[name] = true t_insert(knownNames.uniques, name) end
		end
	end
	local text = table.concat(type(params.texts) == 'table' and params.texts or {}, '\n')
	local out = { gems = {}, uniques = {} }
	for _, kind in ipairs({ 'gems', 'uniques' }) do
		for _, name in ipairs(knownNames[kind]) do
			if phraseIn(text, name) then t_insert(out[kind], name) end
		end
	end
	return { ok = true, result = out }
end
