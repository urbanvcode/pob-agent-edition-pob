-- Agent Edition crafting helper (Stage 6): the mods a base can roll, with PoB's
-- spawn weights, and target items built from mod ids for simulation.
-- Loaded by Tools.lua with (handlers, Ops, shared). Read-only: nothing here
-- changes the build. Odds, prices and plans are worked out by agent-mcp
-- (src/craft/); every number here comes from PoB's own data files
-- (Data/ModExplicit.lua, Essence.lua, ModMaster.lua, ModEldritch.lua).
local handlers, Ops, shared = ...

local t_insert, t_sort = table.insert, table.sort
local m_max, m_min = math.max, math.min
local strip = shared.strip

-- The base and item level to craft on: a slot's item, an item text or a base name.
local function resolveBase(params)
	local item
	if type(params.text) == 'string' and params.text ~= '' then
		local ok, parsed = pcall(new, 'Item', params.text)
		if not ok or not parsed or not parsed.base then return nil, 'PoB could not read that item text' end
		item = parsed
	elseif params.slot then
		local slot = build.itemsTab.slots[tostring(params.slot)]
		if not slot then return nil, 'unknown slot "' .. tostring(params.slot) .. '" (build_summary lists the slot names)' end
		item = slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId]
		if not item and not params.base then return nil, 'no item in ' .. tostring(params.slot) .. ': give base (a base type name)' end
	end
	local baseName = params.base and tostring(params.base) or (item and item.baseName)
	if not baseName or not data.itemBases[baseName] then
		local needle = tostring(baseName or ''):lower()
		local close = {}
		for name in pairs(data.itemBases) do
			if needle ~= '' and name:lower():find(needle, 1, true) then t_insert(close, name) end
		end
		t_sort(close)
		while #close > 8 do table.remove(close) end
		return nil, 'unknown base "' .. tostring(baseName) .. '"' .. (#close > 0 and ('; did you mean: ' .. table.concat(close, ', ')) or '')
	end
	local ilvl = tonumber(params.ilvl) or 84
	ilvl = m_max(1, m_min(100, math.floor(ilvl)))
	local raw = 'Rarity: RARE\nCraft Target\n' .. baseName .. '\nItem Level: ' .. ilvl
	local ok, fresh = pcall(new, 'Item', raw)
	if not ok or not fresh or not fresh.base then return nil, 'PoB could not make a ' .. baseName end
	return { item = fresh, baseName = baseName, ilvl = ilvl, current = item, influence = params.influence }
end

local function lines(mod)
	local l = {}
	for _, s in ipairs(mod) do t_insert(l, s) end
	return l
end
local function tradeIds(mod)
	local ids = {}
	for hash in pairs(mod.tradeHashes or {}) do t_insert(ids, 'explicit.stat_' .. tostring(hash)) end
	t_sort(ids)
	return ids
end

-- params: { slot? | text? | base?, ilvl? (default 84), influence? ("shaper", "elder", ...) }
-- result: base, item class, prefix/suffix limits, every rollable explicit mod with its
-- spawn weight on this base (weight 0 and level > ilvl left out), tiers counted over
-- all item levels, plus essences, bench crafts and eldritch implicits for the class.
handlers.craft_pool = function(params)
	local b, err = resolveBase(params or {})
	if not b then return { ok = false, error = err } end
	local item = b.item
	local includeTags
	if b.influence and item.base.influenceTags then
		local tag = item.base.influenceTags[tostring(b.influence):lower()]
		if not tag then return { ok = false, error = 'unknown influence "' .. tostring(b.influence) .. '" (shaper, elder, crusader, redeemer = eyrie, hunter = basilisk, warlord = adjudicator)' } end
		includeTags = { [tag] = true }
	end
	-- Every explicit prefix/suffix this base can roll at any item level (for tier numbers).
	local all = {}
	for id, mod in pairs(data.itemMods.Explicit or {}) do
		if (mod.type == 'Prefix' or mod.type == 'Suffix') and mod[1] then
			local okW, weight = pcall(item.GetModSpawnWeight, item, mod, includeTags)
			if okW and weight and weight > 0 then
				local influenced = false
				if includeTags then
					local okP, plain = pcall(item.GetModSpawnWeight, item, mod)
					influenced = not (okP and plain and plain > 0)
				end
				t_insert(all, { id = id, mod = mod, weight = weight, influenced = influenced })
			end
		end
	end
	local byGroup = {}
	for _, e in ipairs(all) do
		local key = e.mod.type .. '|' .. tostring(e.mod.group)
		byGroup[key] = byGroup[key] or {}
		t_insert(byGroup[key], e)
	end
	local mods = {}
	for _, list in pairs(byGroup) do
		t_sort(list, function(a, c) return a.mod.level > c.mod.level end)
		for i, e in ipairs(list) do
			if e.mod.level <= b.ilvl then
				t_insert(mods, {
					id = e.id, type = e.mod.type, group = e.mod.group, level = e.mod.level, weight = e.weight,
					tier = i, tiers = #list, name = e.mod.affix, lines = lines(e.mod), tags = e.mod.modTags or {}, trade = tradeIds(e.mod),
					influence = e.influenced or nil,
				})
			end
		end
	end
	t_sort(mods, function(a, c) if a.group ~= c.group then return a.group < c.group end return a.level > c.level end)

	-- Essences for this item class: the guaranteed mod per essence (Data/Essence.lua).
	local essences = {}
	for _, ess in pairs(data.essences or {}) do
		local modId = ess.mods and ess.mods[item.type]
		local mod = modId and (data.itemMods.Explicit[modId] or data.itemMods.Item[modId])
		if mod and mod[1] then
			t_insert(essences, { name = ess.name, tier = ess.tier, modId = modId, type = mod.type, group = mod.group, level = mod.level, lines = lines(mod), trade = tradeIds(mod) })
		end
	end
	t_sort(essences, function(a, c) if a.group ~= c.group then return tostring(a.group) < tostring(c.group) end return a.tier > c.tier end)

	local bench = {}
	for _, mod in ipairs(data.masterMods or {}) do
		if mod.types and mod.types[item.type] and mod[1] and (mod.type == 'Prefix' or mod.type == 'Suffix') then
			t_insert(bench, { type = mod.type, group = mod.group, level = mod.level, name = mod.affix, lines = lines(mod) })
		end
	end
	t_sort(bench, function(a, c) if a.group ~= c.group then return tostring(a.group) < tostring(c.group) end return a.level > c.level end)

	-- Eldritch implicits (Searing Exarch / Eater of Worlds): the best tier per group.
	local eldritch, best = {}, {}
	for id, mod in pairs(data.itemMods.Eldritch or {}) do
		if mod[1] then
			local okW, weight = pcall(item.GetModSpawnWeight, item, mod)
			if okW and weight and weight > 0 then
				local key = mod.type .. '|' .. tostring(mod.group)
				local score = 0
				for v in table.concat(lines(mod), ' '):gmatch('%d+') do score = score + tonumber(v) end
				if not best[key] or score > best[key].score then best[key] = { score = score, mod = mod } end
			end
		end
	end
	for _, e in pairs(best) do t_insert(eldritch, { type = e.mod.type, group = e.mod.group, level = e.mod.level, lines = lines(e.mod) }) end
	t_sort(eldritch, function(a, c) return tostring(a.group) < tostring(c.group) end)

	local limit = (item.type == 'Jewel') and 2 or 3
	local current
	if b.current then
		current = { name = strip(b.current.title or b.current.name or ''), base = b.current.baseName, rarity = b.current.rarity, itemLevel = b.current.itemLevel }
	end
	return { ok = true, result = {
		base = b.baseName, class = item.type, ilvl = b.ilvl, tags = item.base.tags, influence = b.influence, limit = limit,
		mods = mods, essences = essences, bench = bench, eldritch = eldritch, current = current,
		source = 'PoB data: ModExplicit (spawn weights), Essence, ModMaster, ModEldritch',
	} }
end

-- params: { base, ilvl?, sets = { { { id = "IncreasedLife7", range = 0.5 }, ... }, ... } }
-- Builds one rare item text per set with PoB's own crafter (fresh base implicit,
-- the mods at the given roll: 0 = lowest, 1 = highest). Bench mods: { bench = "<line>" }.
handlers.craft_items = function(params)
	local base = data.itemBases[tostring(params.base or '')]
	if not base then return { ok = false, error = 'unknown base "' .. tostring(params.base) .. '"' } end
	local ilvl = tonumber(params.ilvl) or 84
	local out = {}
	for i, set in ipairs(type(params.sets) == 'table' and params.sets or {}) do
		local raw = { 'Rarity: RARE', 'Craft Target', tostring(params.base), 'Crafted: true' }
		local bench = {}
		for _, m in ipairs(set) do
			local mod = m.id and data.itemMods.Explicit[m.id]
			if mod then
				t_insert(raw, mod.type .. ': {range:' .. tostring(m.range or 0.5) .. '}' .. m.id)
			elseif m.bench then
				t_insert(bench, '{crafted}' .. tostring(m.bench))
			end
		end
		t_insert(raw, 'Item Level: ' .. ilvl)
		local implicits = {}
		for l in tostring(base.implicit or ''):gmatch('[^\n]+') do t_insert(implicits, l) end
		t_insert(raw, 'Implicits: ' .. #implicits)
		for _, l in ipairs(implicits) do t_insert(raw, l) end
		local ok, item = pcall(new, 'Item', table.concat(raw, '\n'))
		if ok and item and item.base then
			local okC = pcall(item.Craft, item)
			local text = okC and item:BuildRaw() or nil
			if text and #bench > 0 then text = text .. '\n' .. table.concat(bench, '\n') end
			out[i] = text and { ok = true, text = text } or { ok = false, error = 'PoB could not craft this set' }
		else
			out[i] = { ok = false, error = 'PoB could not read the target item' }
		end
	end
	return { ok = true, result = { items = out } }
end

-- params: { slot }
-- Every bench craft for the slot item's class (highest tier per mod group, average
-- roll), added to a copy of the item as a crafted line; groups already on the item
-- are skipped. agent-mcp simulates each copy with test_items and ranks them.
local function avgRoll(line)
	return (line:gsub('%((%-?[%d%.]+)%-(%-?[%d%.]+)%)', function(a, b) return tostring(math.floor((tonumber(a) + tonumber(b)) / 2 + 0.5)) end))
end
local function lineTemplate(line)
	return (line:gsub('%(%-?[%d%.]+%-%-?[%d%.]+%)', '#'):gsub('%-?%d+%.?%d*', '#'):lower())
end
handlers.craft_fix = function(params)
	local slot = build.itemsTab.slots[tostring(params.slot)]
	if not slot then return { ok = false, error = 'unknown slot "' .. tostring(params.slot) .. '"' } end
	local item = slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId]
	if not item then return { ok = false, error = 'no item in ' .. tostring(params.slot) } end
	if item.rarity == 'UNIQUE' or item.rarity == 'RELIC' or item.corrupted or item.mirrored then return { ok = true, result = { items = {}, base = item.baseName } } end
	local have = {}
	for _, l in ipairs(item.explicitModLines or {}) do
		if not l.crafted then have[lineTemplate(l.line)] = true end
	end
	local best = {}
	for _, mod in ipairs(data.masterMods or {}) do
		if mod.types and mod.types[item.type] and mod[1] and (mod.type == 'Prefix' or mod.type == 'Suffix') then
			local key = mod.type .. '|' .. tostring(mod.group)
			if not best[key] or mod.level > best[key].level then best[key] = mod end
		end
	end
	local raw = item:BuildRaw()
	-- Drop existing crafted lines: a new bench craft replaces the old one.
	local kept = {}
	for l in (raw .. '\n'):gmatch('([^\n]*)\n') do
		if not l:find('{crafted}', 1, true) then t_insert(kept, l) end
	end
	raw = table.concat(kept, '\n')
	local out = {}
	for _, mod in pairs(best) do
		local dup = false
		for _, l in ipairs(mod) do if have[lineTemplate(l)] then dup = true end end
		if not dup then
			local added = {}
			for _, l in ipairs(mod) do t_insert(added, '{crafted}' .. avgRoll(l)) end
			local shown = {}
			for _, l in ipairs(mod) do t_insert(shown, avgRoll(l)) end
			t_insert(out, { type = mod.type, group = mod.group, line = table.concat(shown, ' / '), text = raw .. '\n' .. table.concat(added, '\n') })
		end
	end
	t_sort(out, function(a, c) return tostring(a.group) < tostring(c.group) end)
	return { ok = true, result = { items = out, base = item.baseName } }
end
