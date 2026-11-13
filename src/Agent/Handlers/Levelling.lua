-- Agent Edition levelling coach (Stage 7): an act-by-act plan, milestones (labs,
-- bandit, Pantheon, quest passive points), gear checkpoints and the next steps for
-- a levelling character. Loaded by Core.lua with (handlers, Ops).
--
-- Game facts come from Agent/LevellingData.lua (generated from poewiki, every fact
-- with its source and a short quote); every number for the build comes from PoB.
-- Guide stages are read by levelling_guide_stages on the guide build (side engine
-- or the Guide tab's second build) and passed to levelling_plan / levelling_next.
local handlers, Ops = ...

local t_insert, t_sort, t_concat = table.insert, table.sort, table.concat
local m_min, m_max, m_floor = math.min, math.max, math.floor

local DATA
local function D()
	if not DATA then DATA = LoadModule('Agent/LevellingData') end
	return DATA
end

local LETTER = { Marauder = 'M', Ranger = 'R', Witch = 'W', Duelist = 'D', Templar = 'T', Shadow = 'S', Scion = 'X' }
local MAPS = 11 -- "act" 11 = epilogue and maps

local function num(v)
	if type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge then return v end
	return nil
end

local function cite(key)
	local s = D().sources[key]
	if not s then return nil end
	return { title = s.title, url = s.url, edited = s.edited, retrieved = s.retrieved, outdated = s.outdated or nil }
end

local function lower(s) return tostring(s or ''):lower() end

-- Acts and levels -----------------------------------------------------------------
-- The act whose campaign areas match a character level (area levels from poewiki).
local function actForLevel(level)
	local acts = D().acts
	if level > acts[10].hi then return MAPS end
	local act = 1
	for a = 1, 10 do if acts[a].lo <= level then act = a end end
	return act
end

local function questPointsBefore(act)
	local n = 0
	for _, q in ipairs(D().questPoints) do if q.act < act then n = n + 1 end end
	return n
end

local function questPointsIn(act)
	local out = {}
	for _, q in ipairs(D().questPoints) do if q.act == act then t_insert(out, q.quest) end end
	return out
end

-- Kill all three bandits = one more point (PoB's ExtraPoints), counted from Act 3.
local function banditPoint(act, extra) return act > 2 and (extra or 0) or 0 end

-- About which character level has `points` passive points to spend (levels + quest
-- points of the acts before). Used to place a guide's passives and stages on levels.
local function levelForPoints(points, extra)
	for level = 1, 100 do
		local act = actForLevel(level)
		if level - 1 + questPointsBefore(m_min(act, MAPS)) + banditPoint(act, extra) >= points then return level end
	end
	return 100
end

local function stageLevel(title, points, extra)
	local t = lower(title)
	local lv = tonumber(t:match('lvl?%.?%s*(%d+)') or t:match('level%s*(%d+)') or t:match('lv%s*(%d+)'))
	if lv then return lv, 'title' end
	local a1, a2 = t:match('acts?%s*(%d+)%s*%-%s*(%d+)')
	local act = tonumber(a2 or t:match('acts?%s*(%d+)'))
	if act and act >= 1 and act <= 10 then return D().acts[act].hi, 'title' end
	return levelForPoints(points or 0, extra), 'points'
end

-- The character's act: PoB's own estimate from the allocated points (Build.lua
-- EstimatePlayerProgress), else the act whose areas match the level.
local function currentAct(level, override)
	if tonumber(override) then return m_max(1, m_min(MAPS, tonumber(override))), 'given' end
	-- The same estimate PoB runs on every stat refresh (headless may not have refreshed yet).
	if build.EstimatePlayerProgress then pcall(build.EstimatePlayerProgress, build) end
	local act = build.Act
	if act == 'Endgame' then return MAPS, 'pob' end
	if type(act) == 'number' and act >= 1 then return m_min(act, MAPS), 'pob' end
	return actForLevel(level), 'level'
end

-- Gems: where the class gets them ----------------------------------------------------
local function rewardEntry(name)
	local r = D().rewards
	local n = tostring(name or '')
	return r[n] or r[n .. ' Support'] or r[(n:gsub(' Support$', ''))]
end

local function forClass(code, letter) return code == '*' or (letter and code:find(letter, 1, true) ~= nil) end

-- params: gem name, class letter -> { act, how, quest, npc } (earliest), or nil
local function gemSource(name, letter)
	local e = rewardEntry(name)
	if not e then return nil end
	local best
	for _, q in ipairs(e.q) do
		if forClass(q[3], letter) then best = { act = q[1], how = 'quest', quest = q[2] } break end
	end
	for _, v in ipairs(e.v) do
		if forClass(v[4], letter) and (not best or v[1] < best.act) then best = { act = v[1], how = 'vendor', npc = v[2], quest = v[3] } break end
	end
	return best
end

local function gemReq(name)
	local key = lower(name)
	local id = data.gemForBaseName[key] or data.gemForBaseName[key .. ' support']
	local gem = id and data.gems[id]
	local levels = gem and gem.grantedEffect and gem.grantedEffect.levels
	return levels and levels[1] and levels[1].levelRequirement or nil
end

local function sourceText(src)
	if not src then return 'not a campaign quest or vendor reward for this class (buy, find or check the wiki)' end
	if src.how == 'quest' then return string.format('Act %d quest reward: %s', src.act, src.quest) end
	return string.format('Act %d: buy from %s after %s', src.act, src.npc, src.quest)
end

-- Tree order: allocated nodes in walking order --------------------------------------
-- Breadth-first from the nodes already taken (or the class start), through the target
-- tree only: the order a player would walk them (nearest first).
local function walkOrder(spec, have, ascendancy)
	local target, start = {}, {}
	for id, node in pairs(spec.allocNodes or {}) do
		local isAsc = node.ascendancyName ~= nil
		if isAsc == ascendancy then
			if node.type == 'ClassStart' or node.type == 'AscendClassStart' or have[id] then start[id] = node
			else target[id] = node end
		end
	end
	local order, seen, queue, head = {}, {}, {}, 1
	for id, node in pairs(start) do seen[id] = true t_insert(queue, node) end
	t_sort(queue, function(a, b) return a.id < b.id end)
	while head <= #queue do
		local node = queue[head]
		head = head + 1
		local nexts = {}
		for _, other in ipairs(node.linked or {}) do
			if target[other.id] and not seen[other.id] then seen[other.id] = true t_insert(nexts, other) end
		end
		t_sort(nexts, function(a, b) return a.id < b.id end)
		for _, other in ipairs(nexts) do t_insert(order, other) t_insert(queue, other) end
	end
	-- Unreached (cluster jewel nodes, islands): append in id order.
	local rest = {}
	for id, node in pairs(target) do if not seen[id] then t_insert(rest, node) end end
	t_sort(rest, function(a, b) return a.id < b.id end)
	for _, node in ipairs(rest) do t_insert(order, node) end
	return order
end

local function named(node)
	return node.type == 'Notable' or node.type == 'Keystone' or node.isJewelSocket or node.type == 'Socket'
end
local function nodeName(node) return node.dn or node.name or tostring(node.id) end

-- Main skill of a skill set: the enabled group with an active skill and the most gems.
local function mainGroupOf(groups)
	local best
	for _, g in ipairs(groups or {}) do
		if g.enabled ~= false then
			local active, count, supports = nil, 0, {}
			for _, gem in ipairs(g.gemList or {}) do
				if gem.enabled ~= false and gem.nameSpec and gem.nameSpec ~= '' then
					count = count + 1
					local effect = gem.gemData and gem.gemData.grantedEffect
					if effect and effect.support then t_insert(supports, gem.nameSpec) elseif not active then active = gem.nameSpec end
				end
			end
			if active and (not best or count > best.links) then best = { skill = active, links = count, supports = supports, slot = g.slot } end
		end
	end
	return best
end

local function setGems(groups)
	local out, seen = {}, {}
	for _, g in ipairs(groups or {}) do
		if g.enabled ~= false then
			for _, gem in ipairs(g.gemList or {}) do
				local n = gem.nameSpec
				if gem.enabled ~= false and n and n ~= '' and not seen[n] then
					seen[n] = true
					local effect = gem.gemData and gem.gemData.grantedEffect
					t_insert(out, { name = n, support = effect and effect.support == true or false })
				end
			end
		end
	end
	return out
end

-- Guide side: the stages of the open (guide) build, in levelling order ---------------
-- params: { ids = bool (walking order as node ids too) } -> { stages = { {index, title, points, level, levelFrom, act, passives = {{name, type, point}},
--   small, asc = {names}, skills, gems, main = {skill, links, supports}} }, className, ascendancy, config }
handlers.levelling_guide_stages = function(params)
	params = params or {}
	local treeTab, skillsTab = build.treeTab, build.skillsTab
	local extra = (build.calcsTab.mainOutput or {}).ExtraPoints or 0
	local list = {}
	for i, spec in ipairs(treeTab.specList) do
		local points, asc = 0, 0
		for _, node in pairs(spec.allocNodes or {}) do
			if node.type ~= 'ClassStart' and node.type ~= 'AscendClassStart' then
				if node.ascendancyName then asc = asc + 1 else points = points + 1 end
			end
		end
		local title = tostring(spec.title or 'Default'):gsub('%s*%{[%w,]+%}%s*', ' '):gsub('^%s+', ''):gsub('%s+$', '')
		-- The skill set of the same title (PoB's loadout pairing), else the active one.
		local setId
		for _, id in ipairs(skillsTab.skillSetOrderList or {}) do
			local t = tostring(skillsTab.skillSets[id].title or 'Default')
			if t == spec.title or t:lower() == title:lower() then setId = id end
		end
		if not setId and #(skillsTab.skillSetOrderList or {}) == 1 then setId = skillsTab.skillSetOrderList[1] end
		local set = setId and skillsTab.skillSets[setId]
		local groups = set and set.socketGroupList or (#treeTab.specList == 1 and skillsTab.socketGroupList) or nil
		t_insert(list, { index = i, spec = spec, title = title ~= '' and title or 'Default', points = points, ascPoints = asc, groups = groups })
	end
	t_sort(list, function(a, b) return a.points < b.points or (a.points == b.points and a.index < b.index) end)
	local out = {}
	local have, haveAsc, cumulative = {}, {}, 0
	for _, st in ipairs(list) do
		local passives, small, smallByAct = {}, 0, {}
		local order = walkOrder(st.spec, have, false)
		-- Points this stage adds on top of the previous one, numbered from the previous total.
		local base = cumulative
		local k = 0
		for _, node in ipairs(order) do
			k = k + 1
			if named(node) then
				t_insert(passives, { id = node.id, name = nodeName(node), type = node.type, point = base + k, level = levelForPoints(base + k, extra) })
			else
				small = small + 1
				local a = actForLevel(levelForPoints(base + k, extra))
				smallByAct[a] = (smallByAct[a] or 0) + 1
			end
		end
		local asc, walk, ascIds = {}, nil, nil
		for _, node in ipairs(walkOrder(st.spec, haveAsc, true)) do
			t_insert(asc, nodeName(node))
			if params.ids then ascIds = ascIds or {} t_insert(ascIds, node.id) end
		end
		if params.ids then walk = {} for _, node in ipairs(order) do t_insert(walk, node.id) end end
		for id in pairs(st.spec.allocNodes or {}) do have[id] = true haveAsc[id] = true end
		cumulative = m_max(cumulative, st.points)
		local level, levelFrom = stageLevel(st.title, st.points, extra)
		local gems = setGems(st.groups)
		local skills = {}
		for _, g in ipairs(gems) do if not g.support then t_insert(skills, { name = g.name, req = gemReq(g.name) }) end end
		t_insert(out, { index = st.index, title = st.title, points = st.points, ascPoints = st.ascPoints, level = level, levelFrom = levelFrom,
			act = actForLevel(level), passives = passives, small = small, smallByAct = smallByAct, asc = asc, walk = walk, ascIds = ascIds, gems = gems, skills = skills, main = mainGroupOf(st.groups) })
	end
	local input = build.configTab.input or {}
	return { ok = true, name = build.buildName, className = build.spec.curClassName, ascendancy = build.spec.curAscendClassName,
		stages = out, config = { bandit = input.bandit, pantheonMajorGod = input.pantheonMajorGod, pantheonMinorGod = input.pantheonMinorGod } }
end

-- Player side --------------------------------------------------------------------------
local function playerState(params)
	local spec = build.spec
	local level = tonumber(params.level) or tonumber(build.characterLevel) or 1
	local points, asc = 0, 0
	for _, node in pairs(spec.allocNodes or {}) do
		if node.type ~= 'ClassStart' and node.type ~= 'AscendClassStart' then
			if node.ascendancyName then asc = asc + 1 else points = points + 1 end
		end
	end
	local act, actFrom = currentAct(level, params.act)
	local o = build.calcsTab.mainOutput or {}
	local input = build.configTab.input or {}
	return { level = level, act = act, actFrom = actFrom, points = points, ascPoints = asc, className = spec.curClassName,
		ascendancy = spec.curAscendClassName, letter = LETTER[spec.curClassName], extra = o.ExtraPoints or 0,
		bandit = input.bandit or 'None', major = input.pantheonMajorGod or 'None', minor = input.pantheonMinorGod or 'None',
		penalty = input.resistancePenalty }
end

-- Resistances now and after the next act penalty (PoB's uncapped totals; the penalty is
-- a flat change to every resistance, so after = min(total + change, max)).
local function resistCheck(me)
	local o = build.calcsTab.mainOutput or {}
	local penalties = D().facts.resistPenalty
	local configured = tonumber(me.penalty) or -60 -- PoB's default is "Act 10 (-60%)"
	local now = me.act > 10 and -60 or me.act > 5 and -30 or 0
	local nextP
	for _, p in ipairs(penalties) do if me.act <= p.after then nextP = p break end end
	local out = { configured = configured, expected = now, elements = {}, source = cite('resist'), quotes = {} }
	for _, p in ipairs(penalties) do t_insert(out.quotes, p.quote) end
	if configured ~= now then
		out.configNote = string.format('PoB config "Resistance penalty" is %d%%, your act suggests %d%%: numbers below are corrected for that.', configured, now)
	end
	if nextP then out.nextAfterAct, out.nextPenalty = nextP.after, nextP.value end
	for _, elem in ipairs({ 'Fire', 'Cold', 'Lightning', 'Chaos' }) do
		local final, total, missing = num(o[elem .. 'Resist']), num(o[elem .. 'ResistTotal']), num(o['Missing' .. elem .. 'Resist'])
		if final and total and missing then
			local max = final + missing
			local nowTotal = total + (now - configured)
			local e = { name = elem, max = max, now = m_min(nowTotal, max) }
			e.missingNow = m_max(0, max - e.now)
			if nextP then
				e.after = m_min(nowTotal + (nextP.value - now), max)
				e.missingAfter = m_max(0, max - e.after)
			end
			t_insert(out.elements, e)
		end
	end
	return out
end

local function itemIn(slotName)
	local slot = build.itemsTab.slots[slotName]
	local id = slot and slot.selItemId
	return id and id > 0 and build.itemsTab.items[id] or nil
end

local function hasLine(item, pattern)
	for _, list in ipairs({ item.implicitModLines or {}, item.explicitModLines or {}, item.enchantModLines or {} }) do
		for _, l in ipairs(list) do if lower(l.line):find(pattern) then return true end end
	end
	return false
end

local function maxLinks(item)
	local best, run, last = 0, 0, nil
	for _, s in ipairs(item and item.sockets or {}) do
		if s.group == last then run = run + 1 else run, last = 1, s.group end
		if run > best then best = run end
	end
	return best, #(item and item.sockets or {})
end

local function recipe(id)
	for _, r in ipairs(D().facts.recipes) do if r.id == id then return r end end
end

local function mainSkillKind()
	local ok, flags = pcall(function() return build.calcsTab.mainEnv.player.mainSkill.skillFlags end)
	if not ok or type(flags) ~= 'table' then return nil end
	return flags.spell and 'spell' or flags.attack and 'attack' or nil
end

local function gearCheck(me, target)
	local out = {}
	-- Boots with movement speed
	local boots = itemIn('Boots')
	local ms = boots and hasLine(boots, 'increased movement speed')
	out.boots = { item = boots and boots.name or nil, movementSpeed = ms or false, recipe = recipe('ms_boots'), source = cite('recipes'),
		bandit = 'Kraityn' }
	-- Links of the main skill
	local main = mainGroupOf(build.skillsTab.socketGroupList)
	if main then
		local item = main.slot and itemIn(main.slot)
		local links, sockets = maxLinks(item)
		out.links = { skill = main.skill, gems = main.links, slot = main.slot, item = item and item.name or nil, links = links, sockets = sockets,
			target = target and target.links or nil, targetSkill = target and target.skill or nil, sockets4 = D().facts.sockets, max4 = D().facts.socketMax.quote,
			chromatic = recipe('chromatic'), source = cite('sockets') }
	end
	-- Weapon recipes for the main skill's kind
	local kind = mainSkillKind()
	local ids = kind == 'spell' and { 'spell_weapon' } or { 'phys_weapon', 'added_phys', 'added_fire', 'added_cold', 'added_lightning' }
	out.weapon = { kind = kind or 'unknown', item = (itemIn('Weapon 1') or {}).name, recipes = {} }
	for _, id in ipairs(ids) do t_insert(out.weapon.recipes, recipe(id)) end
	out.weapon.source = cite('recipes')
	return out
end

local function labs(me, ascOrder)
	local out = {}
	local done = m_floor(me.ascPoints / 2)
	for i, lab in ipairs(D().facts.labs) do
		local trialAct = 0
		for _, a in ipairs(lab.trialActs) do trialAct = m_max(trialAct, a) end
		local status = i <= done and 'done' or i == done + 1 and 'next' or 'later'
		local ready = status == 'next' and me.level >= lab.minLevel and (lab.maps and me.act >= MAPS or (not lab.maps and me.act > trialAct)) or false
		local nodes = {}
		for k = (i - 1) * 2 + 1, i * 2 do if ascOrder and ascOrder[k] then t_insert(nodes, ascOrder[k]) end end
		local trials = {}
		for _, t in ipairs(D().facts.trials) do if t.lab == lab.name then t_insert(trials, { act = t.act, area = t.area, areaLevel = t.areaLevel }) end end
		t_insert(out, { name = lab.name, status = status, ready = ready, monsterLevel = lab.monsterLevel, minLevel = lab.minLevel, afterAct = not lab.maps and trialAct or nil,
			maps = lab.maps or nil, trials = trials, nodes = nodes, quote = lab.quote })
	end
	return out, { source = cite('lab'), trialsSource = cite('trials'), points = D().facts.labPoints.quote, shared = D().facts.trialsShared.quote }
end

local function simGain(values)
	local res = handlers.what_if({ ops = { { op = 'config', values = values } }, fields = { 'EffectiveMovementSpeedMod' } })
	if not res or not res.ok then return nil end
	local b, a = res.before, res.after
	local function d(k) return (a[k] or 0) - (b[k] or 0) end
	local function dps(s) return (s.FullDPS or 0) > 0 and s.FullDPS or s.CombinedDPS or s.TotalDPS or 0 end
	local d0 = dps(b)
	return { dpsPct = d0 > 0 and (dps(a) - d0) / d0 * 100 or 0, ehp = d('TotalEHP'), life = d('Life'),
		fire = d('FireResist'), cold = d('ColdResist'), lightning = d('LightningResist'), ms = d('EffectiveMovementSpeedMod') * 100,
		rolledBack = res.rolledBack }
end

local function bandit(me, guideChoice, simulate)
	local f = D().facts
	local out = { act = f.banditAct.act, current = me.bandit, guide = guideChoice, options = {}, source = cite('bandits'), change = f.banditChange.quote }
	for _, b in ipairs(f.bandits) do
		local o = { choice = b.choice, config = b.config, reward = b.reward }
		if simulate and b.config ~= 'None' and b.config ~= me.bandit then o.gain = simGain({ bandit = b.config }) end
		t_insert(out.options, o)
	end
	return out
end

local function pantheon(me, guideMajor, guideMinor)
	local f = D().facts
	local major = {}
	for id, god in pairs(data.pantheons or {}) do major[id] = god.isMajorGod end
	local gods = {}
	for _, g in ipairs(D().gods) do
		local id = g.name:gsub('^The ', 'The'):gsub('%s', '')
		t_insert(gods, { name = g.name, id = id, act = g.act, major = major[id] == true, unlocked = me.act > g.act, quote = g.quote, url = g.url })
	end
	return { firstAct = f.pantheon.firstAct, quote = f.pantheon.quote, swap = f.pantheonSwap.quote, current = { major = me.major, minor = me.minor },
		guide = (guideMajor or guideMinor) and { major = guideMajor, minor = guideMinor } or nil, gods = gods, source = cite('pantheon') }
end

local function questPoints(me)
	local expected = me.level - 1 + questPointsBefore(m_min(me.act, MAPS)) + banditPoint(me.act, me.extra)
	local acts = {}
	for a = 1, 10 do t_insert(acts, { act = a, quests = questPointsIn(a) }) end
	return { allocated = me.points, expectedAtLeast = expected, unspentOrMissed = m_max(0, expected - me.points), total = D().facts.questPointsTotal.value, quote = D().facts.questPointsTotal.quote,
		acts = acts, refunds = D().refunds, source = cite('passive'), questsSource = cite('quests') }
end

-- The target to plan toward: the guide's levelling stages, else the open build itself.
local function targetStages(params)
	if type(params.guide) == 'table' and type(params.guide.stages) == 'table' and #params.guide.stages > 0 then
		return params.guide.stages, 'guide', params.guide
	end
	local own = handlers.levelling_guide_stages({})
	return own.stages, 'build', own
end

local function stageFor(stages, level)
	local pick = stages[1]
	for _, st in ipairs(stages) do if (st.level or 0) <= level then pick = st end end
	return pick
end

-- Act-by-act plan ------------------------------------------------------------------------
local function buildActs(me, stages)
	local acts = {}
	for a = 1, 10 do
		local r = D().acts[a]
		acts[a] = { act = a, levels = { r.lo, r.hi }, questPoints = questPointsIn(a), passives = {}, small = 0, gems = {}, swaps = {}, links = {},
			trials = {}, notes = {} }
	end
	acts[MAPS] = { act = MAPS, levels = { D().acts[10].hi + 1, 100 }, questPoints = {}, passives = {}, small = 0, gems = {}, swaps = {}, links = {}, trials = {}, notes = {} }
	for _, t in ipairs(D().facts.trials) do t_insert(acts[t.act].trials, t.area .. ' (' .. t.lab .. ' Labyrinth trial)') end
	local seenGem, prevMain, prevLinks = {}, nil, 0
	for _, st in ipairs(stages) do
		for _, p in ipairs(st.passives or {}) do t_insert(acts[actForLevel(p.level)].passives, p) end
		local byAct = st.smallByAct
		if type(byAct) == 'table' and next(byAct) then
			for a, n in pairs(byAct) do local i = m_min(tonumber(a) or MAPS, MAPS) acts[i].small = acts[i].small + n end
		else
			local i = m_min(st.act or actForLevel(st.level or 1), MAPS)
			acts[i].small = acts[i].small + (st.small or 0)
		end
		for _, g in ipairs(st.gems or {}) do
			if not seenGem[g.name] then
				seenGem[g.name] = true
				local src = gemSource(g.name, me.letter)
				local req = gemReq(g.name)
				local at = m_max(src and src.act or 1, actForLevel(req or 1))
				t_insert(acts[at].gems, { name = g.name, support = g.support, req = req, source = src, text = sourceText(src), stage = st.title })
			end
		end
		local main = st.main
		if main then
			local act = m_min(st.act or actForLevel(st.level or 1), MAPS)
			if prevMain and lower(main.skill) ~= lower(prevMain) then
				t_insert(acts[act].swaps, { from = prevMain, to = main.skill, level = m_max(st.level or 1, gemReq(main.skill) or 1), stage = st.title })
			end
			if main.links ~= prevLinks then
				t_insert(acts[act].links, { skill = main.skill, links = main.links, supports = main.supports, level = st.level, stage = st.title })
			end
			prevMain, prevLinks = main.skill, main.links
		end
	end
	acts[2].notes = { 'Bandit choice (Deal with the Bandits)' }
	acts[5].notes = { 'Finishing Act 5: -30% to all resistances' }
	acts[6].notes = { 'First Pantheon god (Act 6)' }
	acts[10].notes = { 'Finishing Act 10: another -30% (-60% total)' }
	local list = {}
	for a = 1, MAPS do t_insert(list, acts[a]) end
	return list
end

-- The next steps: what to do now and soon, for the character's level and act.
local function nextSteps(me, plan, limit)
	local steps = {}
	local function add(kind, text, extra)
		local s = { kind = kind, text = text }
		for k, v in pairs(extra or {}) do s[k] = v end
		t_insert(steps, s)
	end
	local act = me.act
	local here = plan.acts[m_min(act, MAPS)]
	-- Quest passive points of this act
	if act <= 10 and #here.questPoints > 0 then
		add('quest points', string.format('Act %d passive point quests: %s', act, t_concat(here.questPoints, ', ')), { source = 'passive' })
	end
	if plan.questPoints.unspentOrMissed > 0 then
		add('quest points', string.format('%d passive point(s) unspent or missed (tree has %d, level %d with the quests before Act %d gives at least %d): check /passives in game',
			plan.questPoints.unspentOrMissed, me.points, me.level, m_min(act, 10), plan.questPoints.expectedAtLeast))
	end
	-- Resistances before the next penalty
	local r = plan.checkpoints.resists
	if r.nextAfterAct then
		local short = {}
		for _, e in ipairs(r.elements) do
			if e.name ~= 'Chaos' and (e.missingAfter or 0) > 0 then t_insert(short, string.format('%s %d%% -> %d%% (+%d to cap)', e.name, e.now, e.after, e.missingAfter)) end
		end
		if #short > 0 and act >= r.nextAfterAct - 1 then
			add('resists', string.format('Before finishing Act %d (%d%% to all resistances): %s', r.nextAfterAct, r.nextPenalty, t_concat(short, ', ')), { source = 'resist' })
		end
	end
	local nowShort = {}
	for _, e in ipairs(r.elements) do if e.name ~= 'Chaos' and e.missingNow > 0 then t_insert(nowShort, string.format('%s +%d', e.name, e.missingNow)) end end
	if #nowShort > 0 then add('resists', 'Uncapped now: ' .. t_concat(nowShort, ', ')) end
	-- Lab
	for _, lab in ipairs(plan.milestones.labs) do
		if lab.status == 'next' then
			local nodes = #lab.nodes > 0 and ('; take ' .. t_concat(lab.nodes, ', ')) or ''
			local need = string.format('%d trials (Acts %d-%d)', #lab.trials, lab.trials[1] and lab.trials[1].act or 0, lab.afterAct or 0)
			if lab.ready then add('lab', string.format('%s Labyrinth (monster level %d): ready once the %s are done%s', lab.name, lab.monsterLevel, need, nodes), { source = 'lab' })
			elseif lab.afterAct and act <= lab.afterAct then
				add('lab', string.format('%s Labyrinth after its %s%s%s', lab.name, need, lab.minLevel > 0 and (' and level ' .. lab.minLevel) or '', nodes), { source = 'lab' })
			elseif lab.maps then
				add('lab', string.format('%s Labyrinth from level %d in maps (an Offering to the Goddess)%s', lab.name, lab.minLevel, nodes), { source = 'lab' })
			end
		end
	end
	-- Bandit
	if act <= 2 then add('bandit', 'Act 2: choose your bandit (Alira, Kraityn, Oak or kill all three)', { source = 'bandits' }) end
	-- Gems and swaps of this act and the next
	for a = act, m_min(act + 1, MAPS) do
		for _, sw in ipairs(plan.acts[a].swaps) do
			if (sw.level or 0) >= me.level - 2 then add('swap', string.format('Swap main skill %s -> %s at level %d', sw.from, sw.to, sw.level)) end
		end
		for _, g in ipairs(plan.acts[a].gems) do
			if not plan.have[lower(g.name)] and (not g.req or g.req <= me.level + 6) then
				add('gem', string.format('%s%s: %s', g.name, g.req and g.req > me.level and (' (level ' .. g.req .. ')') or '', g.text))
			end
		end
	end
	-- Links and boots
	local l = plan.checkpoints.gear.links
	if l and l.target and l.links < l.target then
		add('links', string.format('%s: %d-link now, the plan uses %d (%d sockets need item level %d)', l.skill, l.links, l.target,
			l.target, (function() for _, s in ipairs(l.sockets4) do if s.sockets == m_min(l.target, 6) then return s.ilvl end end return 1 end)()), { source = 'sockets' })
	end
	local b = plan.checkpoints.gear.boots
	if not b.movementSpeed then add('boots', 'Boots without movement speed: vendor recipe ' .. t_concat(b.recipe.inputs, ' + '), { source = 'recipes' }) end
	-- Next passives of the plan
	local nextP = {}
	for _, a in ipairs(plan.acts) do
		for _, p in ipairs(a.passives) do
			if p.point > me.points and #nextP < 3 then t_insert(nextP, string.format('%s (point %d, about level %d)', p.name, p.point, p.level)) end
		end
	end
	if #nextP > 0 then add('passives', 'Next notables: ' .. t_concat(nextP, ', ')) end
	while #steps > (limit or 8) do table.remove(steps) end
	return steps
end

-- params: { guide = levelling_guide_stages result (optional), level, act, simulate, limit }
handlers.levelling_plan = function(params)
	params = params or {}
	local me = playerState(params)
	local stages, from, target = targetStages(params)
	local guideSide = from == 'guide' and target or nil
	local plan = { ok = true, from = from, guideName = guideSide and guideSide.name or nil, me = me, stages = {} }
	for _, st in ipairs(stages) do t_insert(plan.stages, { index = st.index, title = st.title, points = st.points, level = st.level, levelFrom = st.levelFrom, act = st.act,
		main = st.main }) end
	plan.acts = buildActs(me, stages)
	local have = {}
	for _, g in ipairs(setGems(build.skillsTab.socketGroupList)) do have[lower(g.name)] = true end
	plan.have = have
	-- Ascendancy order across stages (2 points per lab).
	local ascOrder, seenAsc = {}, {}
	for _, st in ipairs(stages) do for _, n in ipairs(st.asc or {}) do if not seenAsc[n] then seenAsc[n] = true t_insert(ascOrder, n) end end end
	local labList, labSrc = labs(me, ascOrder)
	local simulate = params.simulate ~= false
	plan.milestones = {
		labs = labList, labFacts = labSrc,
		bandit = bandit(me, guideSide and guideSide.config and guideSide.config.bandit or nil, simulate),
		pantheon = pantheon(me, guideSide and guideSide.config and guideSide.config.pantheonMajorGod, guideSide and guideSide.config and guideSide.config.pantheonMinorGod),
	}
	plan.questPoints = questPoints(me)
	local stageNow = stageFor(stages, me.level)
	plan.stageNow = stageNow and { title = stageNow.title, level = stageNow.level } or nil
	plan.checkpoints = { resists = resistCheck(me), gear = gearCheck(me, stageNow and stageNow.main) }
	plan.next = nextSteps(me, plan, tonumber(params.limit) or 8)
	local d = D()
	plan.data = { generated = d.generated, gameVersion = d.gameVersion, patchCheck = d.patchCheck, licence = d.licence, sources = d.sources }
	plan.have = nil
	return plan
end

-- params: same as levelling_plan; only the character, the act and the next steps (no simulations).
handlers.levelling_next = function(params)
	params = params or {}
	params.simulate = false
	local plan = handlers.levelling_plan(params)
	if not plan.ok then return plan end
	return { ok = true, me = plan.me, from = plan.from, guideName = plan.guideName, stageNow = plan.stageNow, next = plan.next,
		resists = plan.checkpoints.resists, labs = plan.milestones.labs, data = plan.data }
end

-- For the card and tests.
handlers._levelling = { actForLevel = actForLevel, levelForPoints = levelForPoints, gemSource = gemSource, stageLevel = stageLevel, data = D }
