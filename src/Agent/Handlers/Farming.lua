-- Agent Edition farming advisor (Stage 8): what content the build can do, simulated.
-- Loaded by Tools.lua with (handlers, Ops, shared). Everything is simulated in PoB
-- and the build is put back exactly as it was (same capture/restore as what_if).
-- Content facts (area level per map tier, Delirium scaling, ...) come from agent-mcp's
-- cited data file; this side only runs PoB's own calculations.
local handlers, Ops, shared = ...

local t_insert, t_sort = table.insert, table.sort
local m_floor, m_min = math.floor, math.min
local num, dpsOf, recalc, mainOutput = shared.num, shared.dpsOf, shared.recalc, shared.mainOutput
local assumptions, mainSkillName, capture, restore = shared.assumptions, shared.mainSkillName, shared.capture, shared.restore

local function simulate(fn)
	local state = capture()
	local tierControl = build.configTab.varControls and build.configTab.varControls['multiplierMapModTier']
	local tierSel = tierControl and tierControl.selIndex
	local ok, res = pcall(fn)
	if tierControl then tierControl.selIndex = tierSel end
	local errors = restore(state)
	if not ok then return { ok = false, error = tostring(res) } end
	if #errors > 0 then res.rollbackProblem = table.concat(errors, '; ') end
	return res
end

local TYPES = { 'Physical', 'Fire', 'Cold', 'Lightning', 'Chaos' }

-- The numbers the advisor compares, from PoB's current output.
local function measure(o)
	o = o or mainOutput()
	local maxHit, maxType
	for _, t in ipairs(TYPES) do
		local v = num(o[t .. 'MaximumHitTaken'])
		if v and (not maxHit or v < maxHit) then maxHit, maxType = v, t end
	end
	return {
		dps = dpsOf(o), ehp = num(o.TotalEHP) and m_floor(o.TotalEHP),
		maxHit = maxHit and m_floor(maxHit), maxHitType = maxType,
		hits = num(o.NumberOfDamagingHits), enemyDamage = num(o.totalEnemyDamage) and m_floor(o.totalEnemyDamage),
		recovery = (num(o.LifeRegenRecovery) or 0) + (num(o.LifeLeechGainRate) or 0) + (num(o.EnergyShieldRegenRecovery) or 0) + (num(o.EnergyShieldLeechGainRate) or 0),
	}
end

local function set(values)
	local r, err = Ops.set_config(values)
	if not r then error(err) end
	for k, why in pairs(r.rejected or {}) do error('config ' .. k .. ': ' .. tostring(why)) end
	return measure(recalc())
end

local function pct(a, b)
	if not a or not b or b == 0 then return nil end
	return (a - b) / b * 100
end

-- params: { levels = {68, ..., 83}, mods = true, modLevel = 83 }
-- tiers: a standard (map) boss at each area level; pinnacle/uber: PoB's boss presets
-- at their default levels; mods: each map mod PoB models, at red-map values, one at a time.
handlers.farming_check = function(params)
	if not build or not build.configTab then return { ok = false, error = 'build not initialized' } end
	local levels = type(params.levels) == 'table' and params.levels or { 68, 73, 78, 83 }
	return simulate(function()
		local base = measure()
		local clear = set({ enemyIsBoss = 'None' })
		local tiers = {}
		for _, level in ipairs(levels) do
			level = tonumber(level)
			if level then
				local packs = set({ enemyIsBoss = 'None', enemyLevel = level })
				local boss = set({ enemyIsBoss = 'Boss', enemyLevel = level })
				t_insert(tiers, {
					level = level, monsterLife = data.monsterLifeTable[level],
					clearDps = packs.dps, bossDps = boss.dps, hits = boss.hits, packHits = packs.hits,
					maxHit = boss.maxHit, maxHitType = boss.maxHitType, enemyDamage = boss.enemyDamage, ehp = boss.ehp,
				})
			end
		end
		local pinnacle = set({ enemyIsBoss = 'Pinnacle', enemyLevel = 84 })
		local uber = set({ enemyIsBoss = 'Uber', enemyLevel = 85 })

		local mods = {}
		if params.mods ~= false and data.mapMods then
			local modLevel = tonumber(params.modLevel) or 83
			local tierControl = build.configTab.varControls and build.configTab.varControls['multiplierMapModTier']
			if tierControl then tierControl.selIndex = 1 end -- Red (highest values)
			local ref = set({ enemyIsBoss = 'Boss', enemyLevel = modLevel, MapPrefix1 = 'NONE', MapSuffix1 = 'NONE' })
			local refClear = set({ enemyIsBoss = 'None' })
			for _, kind in ipairs({ 'Prefix', 'Suffix' }) do
				for _, entry in ipairs(data.mapMods[kind] or {}) do
					if entry.val ~= 'NONE' then
						local key = 'Map' .. kind .. '1'
						local affix = data.mapMods.AffixData[entry.val] or {}
						local withMod = set({ enemyIsBoss = 'Boss', enemyLevel = modLevel, [key] = entry.val })
						local withModClear = set({ enemyIsBoss = 'None' })
						set({ [key] = 'NONE' })
						local lines = {}
						for i, line in ipairs(affix.tooltipLines or {}) do
							local v = affix.values and affix.values[3]
							if type(v) == 'table' and #(affix.tooltipLines or {}) > 1 then v = v[i] end
							local args = type(v) == 'table' and v or { v or 0 }
							local ok, text = pcall(string.format, line, args[1] or 0, args[2] or args[1] or 0)
							t_insert(lines, ok and text or line)
						end
						t_insert(mods, {
							name = entry.val, kind = kind:lower(), text = table.concat(lines, '; '),
							dpsPct = pct(withModClear.dps, refClear.dps), bossDpsPct = pct(withMod.dps, ref.dps),
							maxHitPct = pct(withMod.maxHit, ref.maxHit), hitsPct = pct(withMod.hits, ref.hits),
							ehpPct = pct(withMod.ehp, ref.ehp), recoveryPct = pct(withMod.recovery, ref.recovery),
						})
					end
				end
			end
		end
		local o = mainOutput()
		local res = {}
		for _, t in ipairs({ 'Fire', 'Cold', 'Lightning', 'Chaos' }) do res[t] = num(o[t .. 'Resist']) end
		return {
			ok = true, base = base, clear = clear, tiers = tiers, pinnacle = pinnacle, uber = uber, mods = mods,
			life = num(o.Life), energyShield = num(o.EnergyShield), resists = res, level = tonumber(build.characterLevel),
			mainSkill = mainSkillName(), assumptions = assumptions(),
		}
	end)
end

-- Atlas presets: for each league mechanic (the mastery a node belongs to in GGG's
-- atlas tree export), its notables and keystones, and the node ids that reach them
-- cheapest-first within `points` (paths included), from the current allocation.
-- params: { mechanics = {"Breach", ...}, points = 30 }. Read-only: atlas { add } applies it.
handlers.farming_atlas = function(params)
	local tab = build and build.atlasTab
	if not tab then return { ok = false, error = 'this PoB has no Atlas tab (needs PoB Agent Edition)' } end
	local atlas = tab:Data()
	if not atlas then return { ok = false, error = 'atlas data not available: ' .. tostring(tab.loadError) } end
	local AtlasData = LoadModule('Agent/AtlasData')
	local want = {}
	for _, m in ipairs(type(params.mechanics) == 'table' and params.mechanics or {}) do want[tostring(m):lower()] = tostring(m) end
	local budget = tonumber(params.points) or 30
	local keys = type(params.keys) == 'table' and params.keys or {}
	-- A notable counts for a mechanic when its name or stats name it (or one of its keywords):
	-- nodes are assigned to the nearest mastery, which can be a neighbour's.
	local function belongs(n, mech)
		local text = (n.name .. ' ' .. table.concat(n.stats or {}, ' ')):lower()
		for word in (tostring(keys[mech] or mech) .. '|' .. mech):gmatch('[^|]+') do
			if text:find(word:lower(), 1, true) then return true end
		end
		return false
	end
	local byMech, names = {}, {}
	for id, n in pairs(atlas.nodes or {}) do
		local mech = n.mechanic
		if mech then
			if not byMech[mech] then byMech[mech] = { special = {}, allocated = 0 }; t_insert(names, mech) end
			if tab.alloc[id] then byMech[mech].allocated = byMech[mech].allocated + 1 end
			if n.type == 'notable' and belongs(n, mech) then t_insert(byMech[mech].special, n) end
			if n.type == 'keystone' then
				byMech[mech].keystones = byMech[mech].keystones or {}
				t_insert(byMech[mech].keystones, { id = tostring(n.id), name = n.name, stats = n.stats, allocated = tab.alloc[id] and true or nil })
			end
		end
	end
	t_sort(names)
	local out = {}
	for _, mech in ipairs(names) do
		if want[mech:lower()] then
			local alloc = {}
			for k, v in pairs(tab.alloc) do alloc[k] = v end
			local picks, ids, used = {}, {}, 0
			local pending = {}
			for _, n in ipairs(byMech[mech].special) do t_insert(pending, n) end
			-- Greedy: repeatedly take the notable with the cheapest path from what is allocated so far.
			while #pending > 0 do
				local best, bestPath, bestIndex
				for i, n in ipairs(pending) do
					if not alloc[n.id] then
						local path = AtlasData.pathTo(atlas, alloc, n.id)
						if path and (not bestPath or #path < #bestPath) then best, bestPath, bestIndex = n, path, i end
					end
				end
				if not best or used + #bestPath > budget then break end
				for _, id in ipairs(bestPath) do
					if not alloc[id] then alloc[id] = true; t_insert(ids, tostring(id)); used = used + 1 end
				end
				t_insert(picks, { id = tostring(best.id), name = best.name, type = best.type, stats = best.stats, cost = #bestPath })
				table.remove(pending, bestIndex)
			end
			local skipped = {}
			for _, n in ipairs(pending) do if not tab.alloc[n.id] then t_insert(skipped, n.name) end end
			t_insert(out, { mechanic = mech, allocated = byMech[mech].allocated, picks = picks, ids = ids, points = used, notPicked = skipped, keystones = byMech[mech].keystones })
		end
	end
	return { ok = true, version = atlas.version, pointsUsed = tab:PointsUsed(), pointsTotal = atlas.points, mechanics = names, presets = out }
end
