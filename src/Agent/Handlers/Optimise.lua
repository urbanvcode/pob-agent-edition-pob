-- Agent Edition optimiser (Stage 4): goal-based min-maxing.
-- Loaded by Tools.lua with (handlers, Ops, shared). A goal sets temporary
-- config (restored afterwards) and a metric; every lever is simulated in PoB
-- and ranked by gain per cost. The build is always put back exactly as it was.
local handlers, Ops, shared = ...

local t_insert, t_sort = table.insert, table.sort
local m_min, m_max, m_abs = math.min, math.max, math.abs
local num, dpsOf, pctChange, strip = shared.num, shared.dpsOf, shared.pctChange, shared.strip
local recalc, assumptions, mainSkillName = shared.recalc, shared.assumptions, shared.mainSkillName
local capture, restore, applyOps = shared.capture, shared.restore, shared.applyOps
local passiveOptions, treeSummary = shared.passiveOptions, shared.treeSummary

local ELEMENTS = { 'Fire', 'Cold', 'Lightning' }
local HIT_TYPES = { 'Physical', 'Fire', 'Cold', 'Lightning', 'Chaos' }

-- Goals -------------------------------------------------------------------------
-- config: temporary config for the goal (nil = the player's config as it is).
-- Weights turn the measured changes into one score (all in percent):
--   st = single-target DPS of the main skill (no culling), dps = combined/full DPS,
--   ehp, hit = weakest maximum hit, ms = movement speed, area = area of effect radius,
--   res = 2 per point of elemental resistance moved towards its cap (chaos 0.5).
local GOALS = {
	bossing = { label = 'single target / bossing', config = { enemyIsBoss = 'Pinnacle' }, w = { st = 1 },
		metric = 'single-target DPS of the main skill against a pinnacle boss (culling excluded)' },
	clear = { label = 'clear speed', config = { enemyIsBoss = 'None' }, w = { dps = 1, ms = 0.5, area = 0.25 },
		metric = 'combined DPS against normal enemies + 0.5 x movement speed + 0.25 x area of effect' },
	tankiness = { label = 'tankiness', w = { ehp = 0.5, hit = 0.5, res = 1 },
		metric = '0.5 x EHP + 0.5 x weakest maximum hit + uncapped resistances' },
	balanced = { label = 'balanced', w = { dps = 1, ehp = 0.5, hit = 0.5, res = 1 },
		metric = 'DPS + 0.5 x EHP + 0.5 x weakest maximum hit + uncapped resistances' },
}

local function weakestHit(o)
	local m
	for _, t in ipairs(HIT_TYPES) do
		local v = num(o[t .. 'MaximumHitTaken'])
		if v and v > 0 and (not m or v < m) then m = v end
	end
	return m or 0
end

-- Single target: the main skill's DPS without the culling bonus (culling only
-- finishes enemies off, it does not help the long part of a boss fight).
local function singleTarget(o)
	local combined = num(o.CombinedDPS) or num(o.TotalDPS) or 0
	local cull = (num(o.CullingDPS) or 0) * (num(o.ReservationDpsMultiplier) or 1)
	local st = combined - cull
	local minion = type(o.Minion) == 'table' and (num(o.Minion.CombinedDPS) or num(o.Minion.TotalDPS)) or 0
	if st <= 0 and minion > 0 then return minion end
	return st
end

local function metrics(o)
	local m = {
		st = singleTarget(o), dps = dpsOf(o), ehp = num(o.TotalEHP) or 0, hit = weakestHit(o),
		ms = num(o.EffectiveMovementSpeedMod) or 1, area = num(o.AreaOfEffectRadius) or 0,
		life = num(o.Life) or 0, miss = {},
		manaUnreserved = num(o.ManaUnreserved) or 0, lifeUnreserved = num(o.LifeUnreserved),
	}
	if m.dps <= 0 and type(o.Minion) == 'table' then m.dps = num(o.Minion.CombinedDPS) or 0 end
	for _, k in ipairs(ELEMENTS) do m.miss[k] = num(o['Missing' .. k .. 'Resist']) or 0 end
	m.miss.Chaos = num(o.MissingChaosResist) or 0
	m.res = {}
	for _, k in ipairs({ 'Fire', 'Cold', 'Lightning', 'Chaos' }) do m.res[k] = num(o[k .. 'Resist']) or 0 end
	return m
end

local function gainOf(base, m)
	local g = {
		stPct = pctChange(m.st, base.st), dpsPct = pctChange(m.dps, base.dps), ehpPct = pctChange(m.ehp, base.ehp),
		hitPct = pctChange(m.hit, base.hit), msPct = (m.ms - base.ms) * 100, areaPct = pctChange(m.area, base.area),
		life = m.life - base.life, res = {}, resFixed = 0,
	}
	for k, miss in pairs(base.miss) do
		local fixed = miss - (m.miss[k] or 0)
		g.resFixed = g.resFixed + (k == 'Chaos' and 0.25 or 1) * fixed
		local d = (m.res[k] or 0) - (base.res[k] or 0)
		if m_abs(d) >= 1 then g.res[k:lower()] = d end
	end
	return g
end

local function scoreOf(g, w)
	return (w.st or 0) * g.stPct + (w.dps or 0) * g.dpsPct + (w.ehp or 0) * g.ehpPct + (w.hit or 0) * g.hitPct
		+ (w.ms or 0) * g.msPct + (w.area or 0) * g.areaPct + (w.res or 0) * 2 * g.resFixed
end

-- "Fix weakest": the goal follows what diagnose finds worst.
local function weakestGoal(hardcore)
	local okD, d = pcall(handlers.diagnose, {})
	local diag = okD and d and d.diagnosis
	if not diag then return 'balanced', 'diagnose failed: balanced' end
	local short = {}
	for _, k in ipairs(ELEMENTS) do
		local r = diag.resist and diag.resist[k]
		if r and r.value and r.max and r.value < r.max then t_insert(short, string.format('%s %d%% of %d%%', k, r.value, r.max)) end
	end
	if #short > 0 then return 'tankiness', 'uncapped resistances (' .. table.concat(short, ', ') .. ')' end
	local survival, damage = {}, {}
	for _, i in ipairs(diag.issues or {}) do
		if i.severity ~= 'info' and (i.category == 'survivability' or i.category == 'reservation') then t_insert(survival, i.message) end
		if i.severity == 'error' and i.category == 'damage' then t_insert(damage, i.message) end
	end
	if #damage > 0 then return 'bossing', damage[1] end
	if #survival > 0 then return 'tankiness', survival[1] end
	local maxHit = 0
	for _, v in pairs(diag.maxHit or {}) do if maxHit == 0 or v < maxHit then maxHit = v end end
	local pool = (diag.pool and diag.pool.life or 0) + (diag.pool and diag.pool.energyShield or 0)
	if hardcore then return 'tankiness', 'hardcore: defence first' end
	if maxHit > 0 and pool > 0 and maxHit < pool then return 'tankiness', 'the weakest maximum hit (' .. maxHit .. ') is below the life + energy shield pool' end
	return 'balanced', 'no clear weak point: balanced'
end

-- Mechanic hint for a lever (agent-mcp adds tags from the stat text too).
local LEVER_MECHANIC = {
	anoint = 'Anoint', flask = 'Flask', pantheon = 'Pantheon', bandit = 'Bandit quest', gem = 'Support gem',
	['gem level'] = 'Skill gem', ['gem quality'] = 'Quality', aura = 'Aura', herald = 'Aura', curse = 'Curse',
	mastery = 'Mastery', respec = 'Passive skill tree',
}

-- Gem level a character of this level can use (same rule as suggest_gems).
local function usableLevel(gemData, charLevel)
	local top = m_min(gemData.naturalMaxLevel or 20, 20)
	local levels = gemData.grantedEffect and gemData.grantedEffect.levels or {}
	for l = top, 1, -1 do
		local req = levels[l] and levels[l].levelRequirement
		if not req or req <= charLevel then return l end
	end
	return nil
end

local UTILITY_FLASKS = { 'Diamond Flask', 'Granite Flask', 'Jade Flask', 'Quartz Flask', 'Silver Flask', 'Basalt Flask',
	'Bismuth Flask', 'Amethyst Flask', 'Ruby Flask', 'Sapphire Flask', 'Topaz Flask', 'Sulphur Flask', 'Stibnite Flask',
	'Aquamarine Flask', 'Corundum Flask', 'Quicksilver Flask' }

-- Standard stat lines for the scaling report: what one more step of each is worth.
local SCALING = {
	{ '10% more Damage', 'damage' }, { '30% increased Damage', 'damage' },
	{ '+30% to Critical Strike Multiplier', 'damage' }, { '50% increased Critical Strike Chance', 'damage' },
	{ '10% increased Attack and Cast Speed', 'damage' }, { 'Damage Penetrates 10% Elemental Resistances', 'damage' },
	{ '+10% to Damage over Time Multiplier', 'damage' }, { '30% increased Area of Effect', 'clear' },
	{ '10% increased Movement Speed', 'clear' },
	{ '+100 to maximum Life', 'defence' }, { '10% increased maximum Life', 'defence' }, { '+100 to maximum Energy Shield', 'defence' },
	{ '+1000 to Armour', 'defence' }, { '+1000 to Evasion Rating', 'defence' }, { '+10% to all Elemental Resistances', 'defence' },
	{ '+1% to all maximum Elemental Resistances', 'defence' }, { '+20% to Chaos Resistance', 'defence' },
	{ '+10% chance to Suppress Spell Damage', 'defence' }, { '+5% Chance to Block Attack Damage', 'defence' },
}

local ALL_LEVERS = { 'passives', 'respec', 'gems', 'auras', 'flasks', 'anoint', 'pantheon', 'config', 'scaling' }

-- params: { goal = bossing|clear|tankiness|balanced|weakest, points = 6, levers = {...}, limit = 12, hardcore = bool }
handlers.optimise = function(params)
	if not build or not build.spec then return { ok = false, error = 'no build loaded' } end
	local started = os.clock()
	local goalName = tostring(params.goal or 'weakest')
	local reason
	if goalName == 'weakest' then goalName, reason = weakestGoal(params.hardcore == true) end
	local goal = GOALS[goalName]
	if not goal then return { ok = false, error = 'unknown goal "' .. tostring(params.goal) .. '" (bossing, clear, tankiness, balanced, weakest)' } end
	local w = {}
	for k, v in pairs(goal.w) do w[k] = v end
	if params.hardcore == true and goalName == 'balanced' then w.ehp, w.hit = 1, 1 end
	local maxPoints = m_min(m_max(tonumber(params.points) or 6, 1), 10)
	local limit = m_min(m_max(tonumber(params.limit) or 12, 1), 30)
	local want = {}
	local leverList = type(params.levers) == 'table' and #params.levers > 0 and params.levers or ALL_LEVERS
	for _, l in ipairs(leverList) do want[tostring(l)] = true end

	local state = capture()
	local okRun, res = pcall(function()
		-- 1. Temporary goal config (restored with everything else at the end).
		local tempConfig = {}
		if goal.config then
			local current = build.configTab.input.enemyIsBoss or 'Pinnacle'
			for k, v in pairs(goal.config) do
				if not (k == 'enemyIsBoss' and v == 'Pinnacle' and current == 'Uber') and current ~= v then tempConfig[k] = v end
			end
			if next(tempConfig) then
				local r, err = Ops.set_config(tempConfig)
				if not r then error(err) end
			end
		end
		local baseOut = recalc()
		local base = metrics(baseOut)
		local calc = build.calcsTab:GetMiscCalculator()
		local okFast, fastOut = pcall(calc, {}, false)
		local baseFast = okFast and metrics(fastOut) or base
		local charLevel = tonumber(build.characterLevel) or 100
		local evaluated = { total = 0 }
		local function counted(lever) evaluated[lever] = (evaluated[lever] or 0) + 1; evaluated.total = evaluated.total + 1 end

		local suggestions, undercount, blocked = {}, {}, {}
		local seen = {}
		local defenceGoal = (w.ehp or 0) > 0
		local function add(lever, text, g, units, extra)
			local s = scoreOf(g, w)
			local key = lever .. '|' .. text .. '|' .. string.format('%.2f', s)
			if seen[key] then return end
			seen[key] = true
			-- What the goal's score does not see, said out loud.
			local warn = {}
			if not defenceGoal and (g.ehpPct < -1 or g.hitPct < -1) then
				if params.hardcore == true then return end -- hardcore: never trade defence away for another goal
				t_insert(warn, string.format('costs %.1f%% EHP / %.1f%% weakest max hit', -g.ehpPct, -g.hitPct))
			end
			if (w.st or 0) + (w.dps or 0) == 0 and m_min(g.stPct, g.dpsPct) < -1 then t_insert(warn, string.format('costs %.1f%% DPS', -m_min(g.stPct, g.dpsPct))) end
			if g.resFixed < -0.5 then t_insert(warn, 'leaves a resistance under its cap') end
			local c = { lever = lever, text = text, gain = g, score = s, units = units, value = s / m_max(units, 0.5), mechanic = LEVER_MECHANIC[lever],
				sideEffects = #warn > 0 and warn or nil }
			for k, v in pairs(extra or {}) do c[k] = v end
			t_insert(suggestions, c)
			return c
		end
		-- One trial with full recalculation: apply ops, measure, put the build back.
		local function trial(lever, ops)
			local s = capture()
			local results, failed = applyOps(ops)
			local m = metrics(recalc())
			local errs = restore(s)
			counted(lever)
			if failed > 0 then
				for _, r in ipairs(results) do if not r.ok then return nil, r.error end end
			end
			if #errs > 0 then error('could not restore the build: ' .. table.concat(errs, '; ')) end
			return m
		end
		local function miscTrial(lever, override, fast)
			counted(lever)
			local okCalc, o = pcall(calc, override, fast and false or nil)
			if not okCalc or type(o) ~= 'table' then return nil end
			return metrics(o)
		end

		local spec = build.spec
		local tree = treeSummary()
		local pointsFree = tree.pointsAtLevel - tree.pointsUsed
		local gemLevels = {}

		-- 2. Passives within N points (notables, keystones, masteries) with their path.
		local additions = {}
		if want.passives or want.respec then
			passiveOptions(maxPoints, function(node, pathNodes, points, name, stats, extra)
				if (evaluated.passives or 0) >= 300 then return end
				local m = miscTrial('passives', { addNodes = pathNodes })
				if not m then return end
				local g = gainOf(base, m)
				local s = scoreOf(g, w)
				local ids = {}
				for p in pairs(pathNodes) do ids[p.id] = true end
				local op = extra and extra.effect and { op = 'mastery', node = node.id, effect = extra.effect } or { op = 'alloc', node = node.id }
				local a = { node = node, name = name, points = points, stats = stats, gain = g, score = s, pathNodes = pathNodes, ids = ids,
					type = extra and extra.effect and 'Mastery' or node.type, effect = extra and extra.effect, op = op }
				t_insert(additions, a)
			end)
			if want.passives then
				t_sort(additions, function(a, b) return a.score / a.points > b.score / b.points end)
				local n = 0
				for _, a in ipairs(additions) do
					if a.score > 0.05 and n < 8 then
						n = n + 1
						add(a.type == 'Mastery' and 'mastery' or 'passive', a.name .. (a.type == 'Keystone' and ' (keystone)' or ''), a.gain, a.points,
							{ id = a.node.id, effect = a.effect, points = a.points, stats = a.stats, kind = a.type, ops = { a.op },
							  cost = { points = a.points, free = pointsFree >= a.points or nil } })
					end
				end
			end
			-- Allocated masteries: a better effect on the same mastery.
			if want.passives then
				local masteryTries = {}
				for id, node in pairs(spec.allocNodes) do
					if node.type == 'Mastery' and node.masteryEffects and spec.masterySelections[id] then
						for _, e in ipairs(node.masteryEffects) do
							local taken = false
							for _, effectId in pairs(spec.masterySelections) do if effectId == e.effect then taken = true end end
							local effect = spec.tree.masteryEffects[e.effect]
							if effect and not taken then
								local effectNode = { id = node.id, type = node.type, name = node.name, dn = node.dn, sd = {} }
								for i, sd in ipairs(effect.sd or {}) do effectNode.sd[i] = sd end
								spec.tree:ProcessStats(effectNode)
								if effectNode.modKey ~= '' then
									local m = miscTrial('passives', { removeNodes = { [node] = true }, addNodes = { [effectNode] = true } })
									if m then
										local g = gainOf(base, m)
										if scoreOf(g, w) > 0.2 then
											t_insert(masteryTries, { node = node, effect = e.effect, stats = effect.sd, gain = g, score = scoreOf(g, w) })
										end
									end
								end
							end
						end
					end
				end
				t_sort(masteryTries, function(a, b) return a.score > b.score end)
				for i = 1, m_min(3, #masteryTries) do
					local t = masteryTries[i]
					add('mastery', 'Change the effect of ' .. (t.node.dn or t.node.name), t.gain, 1,
						{ id = t.node.id, effect = t.effect, stats = t.stats, kind = 'mastery swap', ops = { { op = 'mastery', node = t.node.id, effect = t.effect } },
						  cost = { note = 'changing a mastery effect: cost not verified (kb_lookup "mastery")' } })
				end
			end
		end

		-- 3. Respecs: take out the passives that do least for this goal and spend the
		--    points on a better target. 1 Orb of Regret per point taken out.
		if want.respec then
			local removals = {}
			for id, node in pairs(spec.allocNodes) do
				if node.type ~= 'ClassStart' and node.type ~= 'AscendClassStart' and not node.ascendancyName and node.type ~= 'Socket'
					and not node.isJewelSocket and node.depends and #node.depends >= 1 and #node.depends <= maxPoints then
					local R, names, socket = {}, {}, false
					for _, dep in ipairs(node.depends) do
						R[dep] = true
						if dep.type == 'Socket' or dep.isJewelSocket or dep.ascendancyName then socket = true end
						if dep.type == 'Notable' or dep.type == 'Keystone' or dep.type == 'Mastery' then t_insert(names, dep.dn or dep.name) end
					end
					if not socket and (evaluated.respec or 0) < 200 then
						local m = miscTrial('respec', { removeNodes = R })
						if m then
							local g = gainOf(base, m)
							local loss = -scoreOf(g, w)
							t_insert(removals, { node = node, R = R, points = #node.depends, loss = loss, perPoint = loss / #node.depends, gain = g,
								names = #names > 0 and names or { (node.dn or node.name) .. ' (small passive)' } })
						end
					end
				end
			end
			t_sort(removals, function(a, b) return a.perPoint < b.perPoint end)
			t_sort(additions, function(a, b) return a.score > b.score end)
			local seenRemoval, made = {}, 0
			for _, r in ipairs(removals) do
				if made >= 3 or r.perPoint > 2 then break end
				local key = table.concat(r.names, ',')
				if not seenRemoval[key] then
					seenRemoval[key] = true
					for _, a in ipairs(additions) do
						if a.points <= r.points + m_max(pointsFree, 0) and a.score > r.loss + 0.2 then
							local overlap = false
							for dep in pairs(r.R) do if a.ids[dep.id] then overlap = true end end
							if not overlap then
								local m = miscTrial('respec', { removeNodes = r.R, addNodes = a.pathNodes })
								if m then
									local g = gainOf(base, m)
									if scoreOf(g, w) > 0.3 then
										made = made + 1
										add('respec', 'Respec ' .. table.concat(r.names, ', ') .. ' (' .. r.points .. ' points) into ' .. a.name .. ' (' .. a.points .. ' points)', g, r.points,
											{ id = a.node.id, points = a.points, refund = r.points, stats = a.stats, removed = r.names,
											  ops = { { op = 'dealloc', node = r.node.id }, a.op }, cost = { regret = r.points } })
									end
								end
								break
							end
						end
					end
				end
			end
		end

		-- 4. Gems: support swaps and gem levels (suggest_gems), quality to 20.
		if want.gems then
			local okG, gres = pcall(handlers.suggest_gems, { limit = 4 })
			if okG and gres and gres.ok then
				counted('gems')
				evaluated.gems = (evaluated.gems or 0) + (gres.tried or 0)
				evaluated.total = evaluated.total + (gres.tried or 0)
				-- suggest_gems measures combined/full DPS; that number stands in for the goal's DPS measure.
				local function gemGain(pct) return { stPct = pct, dpsPct = pct, ehpPct = 0, hitPct = 0, msPct = 0, areaPct = 0, life = 0, res = {}, resFixed = 0 } end
				for i, c in ipairs(gres.candidates or {}) do
					if i <= 3 and c.dpsPct > 0.5 and gres.target then
						add('gem', 'Swap ' .. tostring(gres.targetName) .. ' for ' .. c.name .. ' in ' .. tostring(gres.skill), gemGain(c.dpsPct), 1,
							{ name = c.name, warning = c.warning, group = gres.group,
							  ops = { { op = 'remove_gem', group = gres.group, gem = gres.target }, { op = 'add_gem', group = gres.group, name = c.name, level = c.level, quality = 20 } },
							  cost = { buy = c.name, awakened = c.awakened } })
					end
				end
				-- Gem levels come with experience, so they are not an action. agent-mcp shows them
				-- as a short note, or (trade/mixed) as a priced 20/20 copy when level 20 is usable.
				local sg = build.skillsTab.socketGroupList[gres.group]
				for _, u in ipairs(gres.levelUps or {}) do
					local gem = sg and sg.gemList[u.gem]
					local top = gem and gem.gemData and m_min(gem.gemData.naturalMaxLevel or 20, 20) or 20
					t_insert(gemLevels, { name = u.name, from = u.from, to = u.to, dpsPct = u.dpsPct, group = gres.group, gem = u.gem,
						quality = gem and gem.quality or 0, maxLevel = top, canUseMax = u.to >= top })
				end
			end
			local groupIndex = build.mainSocketGroup
			local group = build.skillsTab.socketGroupList[groupIndex]
			for i, gem in ipairs(group and group.gemList or {}) do
				if gem.gemData and gem.enabled ~= false and (gem.quality or 0) < 20 and (evaluated['gem quality'] or 0) < 6 then
					local m = trial('gem quality', { { op = 'gem', group = groupIndex, gem = i, quality = 20 } })
					if m then
						local g = gainOf(base, m)
						if scoreOf(g, w) > 0.3 then
							add('gem quality', 'Quality ' .. (gem.nameSpec or '?') .. ' ' .. (gem.quality or 0) .. '% -> 20%', g, 1,
								{ ops = { { op = 'gem', group = groupIndex, gem = i, quality = 20 } }, cost = { buy = "Gemcutter's Prism", count = math.ceil((20 - (gem.quality or 0)) / 5) } })
						end
					end
				end
			end
		end

		-- 5. Auras, heralds and curses not in the build yet, each as a new skill group.
		if want.auras then
			local have = {}
			for _, g in ipairs(build.skillsTab.socketGroupList) do
				for _, gem in ipairs(g.gemList or {}) do have[(gem.nameSpec or ''):lower()] = true end
			end
			local tries = {}
			for _, gemData in pairs(build.data.gems) do
				local tags = gemData.tags or {}
				local effect = gemData.grantedEffect
				local kind = tags.herald and 'herald' or (tags.curse and 'curse') or (tags.aura and 'aura') or nil
				if kind and effect and not effect.support and not effect.fromItem and gemData.name and not gemData.name:match('^Vaal ')
					and not have[gemData.name:lower()] and not tags.mark then
					local level = usableLevel(gemData, charLevel)
					if level then
						local m, err = trial('auras', { { op = 'add_group', label = 'Optimiser test', gems = { { name = gemData.name, level = level } } } })
						if m then
							local g = gainOf(base, m)
							local s = scoreOf(g, w)
							if s > 0.3 then
								local fits = m.manaUnreserved >= 0 and (m.lifeUnreserved == nil or m.lifeUnreserved > 0)
								local entry = { kind = kind, name = gemData.name, level = level, gain = g, score = s }
								if fits then t_insert(tries, entry) else t_insert(blocked, { lever = kind, name = gemData.name, gain = g, score = s, why = 'not enough unreserved mana or life to reserve it' }) end
							end
						end
					end
				end
			end
			t_sort(tries, function(a, b) return a.score > b.score end)
			for i = 1, m_min(4, #tries) do
				local t = tries[i]
				add(t.kind, 'Add ' .. t.name .. ' (' .. t.kind .. ', level ' .. t.level .. ')', t.gain, 1,
					{ name = t.name, ops = { { op = 'add_group', label = t.name, gems = { { name = t.name, level = t.level } } } },
					  cost = { buy = t.name, note = 'needs a free gem socket' } })
			end
			t_sort(blocked, function(a, b) return a.score > b.score end)
			while #blocked > 4 do table.remove(blocked) end
		end

		-- 6. Flasks: equipped flasks switched off (under-counting), utility flasks in an empty slot.
		if want.flasks then
			local set = build.itemsTab.activeItemSet
			local emptySlot
			for i = 1, 5 do
				local slotName = 'Flask ' .. i
				local slot = build.itemsTab.slots[slotName]
				local item = slot and slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId]
				if item then
					if set and set[slotName] and not set[slotName].active then
						local m = trial('flasks', { { op = 'flask', index = i, active = true } })
						if m then
							local g = gainOf(base, m)
							if scoreOf(g, w) > 0.3 then
								t_insert(undercount, { lever = 'flask', text = (item.title or item.baseName or slotName) .. ' is switched off in PoB', gain = g, score = scoreOf(g, w),
									ops = { { op = 'flask', index = i, active = true } } })
							end
						end
					end
				elseif not emptySlot then
					emptySlot = i
				end
			end
			if emptySlot then
				local tries = {}
				for _, baseName in ipairs(UTILITY_FLASKS) do
					local b = data.itemBases[baseName]
					if b and (not b.req or (b.req.level or 0) <= charLevel) then
						local ops = { { op = 'equip', slot = 'Flask ' .. emptySlot, text = 'Rarity: NORMAL\n' .. baseName }, { op = 'flask', index = emptySlot, active = true } }
						local m = trial('flasks', ops)
						if m then
							local g = gainOf(base, m)
							if scoreOf(g, w) > 0.3 then t_insert(tries, { name = baseName, gain = g, score = scoreOf(g, w), ops = ops }) end
						end
					end
				end
				t_sort(tries, function(a, b) return a.score > b.score end)
				for i = 1, m_min(2, #tries) do
					add('flask', tries[i].name .. ' in the empty Flask ' .. emptySlot .. ' slot (plain base, no mods)', tries[i].gain, 1,
						{ name = tries[i].name, ops = tries[i].ops, cost = { buy = tries[i].name } })
				end
			end
		end

		-- 7. Anoint: every anointable notable on the amulet, against the current anoint.
		if want.anoint then
			local tab = build.itemsTab
			local slot = tab.slots.Amulet
			local item = slot and slot.selItemId and tab.items[slot.selItemId]
			if item and tab.anointItem then
				local prevItem, prevSlot = tab.displayItem, tab.anointEnchantSlot
				local okA, errA = pcall(function()
					tab:SetDisplayItem(item)
					tab.anointEnchantSlot = 1
					local repSlotName = item.base and item.base.type or 'Amulet'
					local tries = {}
					for id, node in pairs(spec.tree.nodes or {}) do
						if node.recipe and node.dn and node.modKey ~= '' and not spec.allocNodes[id] then
							local m = miscTrial('anoint', { repSlotName = repSlotName, repItem = tab:anointItem(node) }, true)
							if m then
								local g = gainOf(baseFast, m)
								local s = scoreOf(g, w)
								if s > 0.3 then t_insert(tries, { name = node.dn, gain = g, score = s, recipe = node.recipe, stats = node.sd }) end
							end
						end
					end
					t_sort(tries, function(a, b) return a.score > b.score end)
					for i = 1, m_min(3, #tries) do
						local recipe = {}
						for _, oil in ipairs(tries[i].recipe or {}) do t_insert(recipe, tostring(oil)) end
						add('anoint', 'Anoint ' .. tries[i].name .. ' on the amulet', tries[i].gain, 1,
							{ name = tries[i].name, stats = tries[i].stats, recipe = recipe, cost = { buy = table.concat(recipe, ', '), note = 'replaces the current anoint' } })
					end
				end)
				tab:SetDisplayItem(prevItem)
				tab.anointEnchantSlot = prevSlot
				if not okA then t_insert(blocked, { lever = 'anoint', name = 'anoint', why = tostring(errA) }) end
			end
		end

		-- 8. Pantheon and bandit (config options of PoB).
		if want.pantheon then
			local okLoad, varList = pcall(LoadModule, 'Modules/ConfigOptions')
			if okLoad and type(varList) == 'table' then
				for _, var in ipairs(varList) do
					if var.var == 'pantheonMajorGod' or var.var == 'pantheonMinorGod' or var.var == 'bandit' then
						local current = build.configTab.input[var.var] or 'None'
						local best
						for _, e in ipairs(var.list or {}) do
							if e.val ~= current then
								local ops = { { op = 'config', values = { [var.var] = e.val } } }
								local m = trial('pantheon', ops)
								if m then
									local g = gainOf(base, m)
									local s = scoreOf(g, w)
									if s > 0.3 and (not best or s > best.score) then best = { label = strip(e.label), val = e.val, gain = g, score = s, ops = ops } end
								end
							end
						end
						if best then
							local isBandit = var.var == 'bandit'
							add(isBandit and 'bandit' or 'pantheon', (isBandit and 'Bandit: ' or (var.var == 'pantheonMajorGod' and 'Major Pantheon: ' or 'Minor Pantheon: ')) .. best.label, best.gain, 1,
								{ ops = best.ops, cost = { note = isBandit and 'the bandit is chosen in Act 2 (kb_lookup "bandit")' or 'switch in town (kb_lookup "pantheon")' } })
						end
					end
				end
			end
		end

		-- 9. Config the player may be under-counting: options PoB shows for this build that are off
		--    and would raise the goal's numbers. Only true if it happens in the player's fights.
		if want.config then
			local okLoad, varList = pcall(LoadModule, 'Modules/ConfigOptions')
			local controls = build.configTab.varControls or {}
			if okLoad and type(varList) == 'table' then
				for _, var in ipairs(varList) do
					if (evaluated.config or 0) >= 60 then break end
					if var.type == 'check' and var.var and not build.configTab.input[var.var] and controls[var.var] then
						local okShown, shown = pcall(controls[var.var].IsShown, controls[var.var])
						if okShown and shown then
							local ops = { { op = 'config', values = { [var.var] = true } } }
							local m = trial('config', ops)
							if m then
								local g = gainOf(base, m)
								local s = scoreOf(g, w)
								if s > 1 then t_insert(undercount, { lever = 'config', key = var.var, text = strip(var.label), gain = g, score = s, ops = ops }) end
							end
						end
					end
				end
			end
		end
		t_sort(undercount, function(a, b) return a.score > b.score end)
		while #undercount > 8 do table.remove(undercount) end

		-- 10. Scaling report: what one standard step of each stat is worth for this build.
		local scaling = {}
		if want.scaling then
			for i, line in ipairs(SCALING) do
				local node = { id = 9900000 + i, type = 'Normal', name = 'Scaling', dn = 'Scaling', sd = { line[1] } }
				spec.tree:ProcessStats(node)
				if node.modKey ~= '' then
					local m = miscTrial('scaling', { addNodes = { [node] = true } })
					if m then
						local g = gainOf(base, m)
						t_insert(scaling, { stat = line[1], group = line[2], gain = g, score = scoreOf(g, w) })
					end
				end
			end
			t_sort(scaling, function(a, b) return a.score > b.score end)
		end

		-- Rank: gain per cost (points, regret orbs, or 1 for a one-off change).
		local ranked = {}
		for _, s in ipairs(suggestions) do if s.score > 0.05 then t_insert(ranked, s) end end
		t_sort(ranked, function(a, b) if a.value ~= b.value then return a.value > b.value end return a.score > b.score end)
		local total = #ranked
		while #ranked > limit do table.remove(ranked) end
		return {
			ok = true, goal = goalName, goalLabel = goal.label, reason = reason, metric = goal.metric, weights = w,
			tempConfig = tempConfig, assumptions = assumptions(), mainSkill = mainSkillName(),
			base = { singleTargetDps = base.st, dps = base.dps, ehp = base.ehp, weakestHit = base.hit, movementSpeed = base.ms, life = base.life, missingRes = base.miss },
			suggestions = ranked, gemLevels = gemLevels, more = total - #ranked, undercount = undercount, blocked = blocked, scaling = scaling,
			pointsFree = pointsFree, maxPoints = maxPoints, evaluated = evaluated,
		}
	end)
	local errors = restore(state)
	if not okRun then return { ok = false, error = tostring(res) } end
	res.seconds = math.floor((os.clock() - started) * 10 + 0.5) / 10
	if #errors > 0 then res.rollbackProblem = table.concat(errors, '; ') end
	return res
end
