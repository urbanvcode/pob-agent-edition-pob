-- Agent Edition: tree compare as a respec planner.
-- Loaded by Tools.lua with (handlers, Ops, shared). The differences between the
-- active tree and another one (a spec of this build, another build, the last
-- character sync) come from Agent/TreeDiff.lua; this file measures them in PoB:
--   each change alone: PoB's misc calculator on a scratch spec (nothing changes);
--   the ticked changes together: applied for real and rolled back, with the same
--   checks what_if makes (skills left without mana, attributes, resistance caps).
-- The Tree tab's changes panel and agent-mcp's compare { tree } both call tree_plan.
local handlers, Ops, shared = ...

local t_insert = table.insert
local m_floor, m_min, m_max, m_abs = math.floor, math.min, math.max, math.abs
local num, dpsOf, keyStats, recalc = shared.num, shared.dpsOf, shared.keyStats, shared.recalc
local capture, restore, costWarnings = shared.capture, shared.restore, shared.costWarnings
local assumptions, treeSummary = shared.assumptions, shared.treeSummary
local ops = shared.ops

local TreeDiff = LoadModule("Agent/TreeDiff")

local HIT_TYPES = { 'Physical', 'Fire', 'Cold', 'Lightning', 'Chaos' }
local ELEMENTS = { 'Fire', 'Cold', 'Lightning' }
local AVOID = { 'Freeze', 'Stun', 'Chill', 'Shock', 'Ignite', 'Bleed', 'Poison' }

local function weakestHit(o)
	local low
	for _, t in ipairs(HIT_TYPES) do
		local v = num(o and o[t .. 'MaximumHitTaken'])
		if v and (not low or v < low) then low = v end
	end
	return low or 0
end

local function metrics(o)
	return { dps = dpsOf(o), ehp = num(o and o.TotalEHP) or 0, hit = weakestHit(o) }
end

local function pct(a, b)
	if not b or b == 0 then return 0 end
	return (a - b) / m_abs(b) * 100
end

local function gainOf(after, before)
	local g = { }
	for _, k in ipairs({ 'dps', 'ehp', 'hit' }) do
		g[k] = after[k] - before[k]
		g[k .. 'Pct'] = pct(after[k], before[k])
	end
	return g
end

-- A tree of another build: its active one, or a stage / loadout / spec by title or number.
local function pickSpec(entry, want)
	local list = entry.treeTab and entry.treeTab.specList or { entry.spec }
	if want == nil or want == '' then return entry.spec, nil end
	local index = tonumber(want)
	if not index then
		local w = tostring(want):lower()
		for i, s in ipairs(list) do if (s.title or ''):lower() == w then index = i end end
		if not index then for i, s in ipairs(list) do if (s.title or ''):lower():find(w, 1, true) then index = index or i end end end
	end
	if index and list[index] then return list[index], list[index].title or ('tree ' .. index) end
	local names = { }
	for i, s in ipairs(list) do t_insert(names, i .. ' = ' .. (s.title or 'Default')) end
	return nil, 'no stage or tree "' .. tostring(want) .. '" in that build (trees: ' .. table.concat(names, ', ') .. ')'
end
handlers._pickSpec = pickSpec

-- Which tree to compare with. Returns otherSpec, otherBuild, title, source or nil, error.
local function resolveOther(params)
	if params.otherSpec then return params.otherSpec, params.otherBuild, params.title or 'other tree', 'object' end
	local tab = build.treeTab
	if type(params.xml) == 'string' and params.xml ~= '' then
		local ok, entry = pcall(new, 'CompareEntry', params.xml, params.title or 'Other build')
		if not ok or not entry or not entry.spec then return nil, 'could not load that build: ' .. tostring(entry) end
		local spec, title = pickSpec(entry, params.spec)
		if not spec then return nil, title end
		return spec, entry, (params.title or 'Other build') .. (title and (' / ' .. title) or ''), 'build'
	end
	local want = params.compare
	if want == nil then return nil, 'compare: a tree number or title, a build name or "last sync"' end
	local index = tonumber(want)
	if not index then
		local w = tostring(want):lower()
		for i, spec in ipairs(tab.specList) do
			if (spec.title or ('Spec ' .. i)):lower() == w then index = i end
		end
		if not index then
			for i, spec in ipairs(tab.specList) do
				if (spec.title or ''):lower():find(w, 1, true) then index = index or i end
			end
		end
	end
	local spec = index and tab.specList[index]
	if not spec then
		local names = { }
		for i, s in ipairs(tab.specList) do t_insert(names, i .. ' = ' .. (s.title or 'Default')) end
		return nil, 'no tree "' .. tostring(want) .. '" in this build (trees: ' .. table.concat(names, ', ') .. ')'
	end
	return spec, nil, (spec.title or ('Spec ' .. index)), 'spec', index
end

-- Plan warnings: what the chosen set breaks, measured like what_if (Tools.lua).
local function planWarnings(baseOut, o, beforeCost, dropped)
	local W = { }
	local had = { }
	for _, w in ipairs(beforeCost or { }) do had[w.skill .. '|' .. w.resource] = true end
	local unreserved, baseUnreserved = num(o.ManaUnreserved), num(baseOut.ManaUnreserved)
	if unreserved and unreserved < 0 and not (baseUnreserved and baseUnreserved < 0) then
		t_insert(W, { kind = 'mana', text = 'Mana is over-reserved (' .. m_floor(unreserved) .. ' unreserved): reserving skills and skill costs do not all fit' })
	end
	for _, w in ipairs(costWarnings(o)) do
		if not had[w.skill .. '|' .. w.resource] then t_insert(W, { kind = 'mana', skill = w.skill, text = w.text }) end
	end
	local life, baseLife = num(o.LifeUnreserved), num(baseOut.LifeUnreserved)
	if life and life <= 0 and not (baseLife and baseLife <= 0) then
		t_insert(W, { kind = 'reservation', text = 'Unreserved life is ' .. m_floor(life) .. ' (life reservation does not fit)' })
	end
	for _, s in ipairs(handlers.attribute_short and handlers.attribute_short(o, baseOut) or { }) do
		t_insert(W, { kind = 'attributes', text = string.format('Needs %d %s but has %d (%d short): gems or items that need it stop working', m_floor(s.need), s.attr, m_floor(s.have), math.ceil(s.short)) })
	end
	for _, r in ipairs(ELEMENTS) do
		local v, b = num(o[r .. 'Resist']) or 0, num(baseOut[r .. 'Resist']) or 0
		local miss, bmiss = num(o['Missing' .. r .. 'Resist']) or 0, num(baseOut['Missing' .. r .. 'Resist']) or 0
		if miss > 0 and miss > bmiss + 0.5 then
			t_insert(W, { kind = 'resist', text = string.format('%s resistance %s the cap: %d%% -> %d%% (%d%% short)', r, bmiss > 0 and 'further under' or 'falls under', b, v, miss) })
		end
	end
	local chaos, bchaos = num(o.ChaosResist) or 0, num(baseOut.ChaosResist) or 0
	if chaos < 0 and chaos < bchaos - 0.5 then
		t_insert(W, { kind = 'resist', text = string.format('Chaos resistance drops: %d%% -> %d%%', bchaos, chaos) })
	end
	for _, a in ipairs(AVOID) do
		local v, b = num(o[a .. 'AvoidChance']) or 0, num(baseOut[a .. 'AvoidChance']) or 0
		if b >= 100 and v < 100 then
			t_insert(W, { kind = 'immunity', text = string.format('No longer immune to %s (%d%% avoidance)', a:lower(), m_floor(v)) })
		end
	end
	if dropped and #dropped > 0 then
		t_insert(W, { kind = 'path', text = 'These nodes lose their path and are left out: ' .. table.concat(dropped, ', ') .. ' (tick the change that leads to them, or untick the removal that cuts them off)' })
	end
	return W
end

-- Nodes meant to stay that PoB left out (no path): notables by name, small passives counted.
local function droppedNames(spec, intended, result)
	local out, small, seen = { }, 0, { }
	for id in pairs(intended) do
		local node = spec.nodes[id]
		if not result.allocNodes[id] and node and node.type ~= 'ClassStart' and node.type ~= 'AscendClassStart' then
			local name = node.dn or node.name or tostring(id)
			if node.type == 'Normal' or node.type == 'Mastery' then small = small + 1
			elseif not seen[name] then seen[name] = true t_insert(out, name) end
		end
	end
	table.sort(out)
	if small > 0 then t_insert(out, small .. ' small passive' .. (small == 1 and '' or 's')) end
	return out
end

-- Put a tree state on a spec (PoB's own undo-state import), with its jewels.
local function applyState(spec, state, jewels)
	spec.jewels = jewels
	spec:RestoreUndoState(state)
	if spec.BuildClusterJewelGraphs then spec:BuildClusterJewelGraphs() end
end

-- The plan for the active tree against another one.
-- params: { compare | xml+title | otherSpec+otherBuild (Tree tab), skip = {change ids}, measure = bool (default true),
--           save_as = "title" (keep the ticked set as a new tree), fields }
handlers.tree_plan = function(params)
	params = params or { }
	if not build or not build.spec or not build.treeTab then return { ok = false, error = 'no build open' } end
	local base = build.spec
	local other, otherBuild, title, source, otherIndex = resolveOther(params)
	if not other then return { ok = false, error = otherBuild } end
	if other == base then return { ok = false, error = 'that is the active tree; compare it with another one' } end
	local d, err = TreeDiff.diff(base, other, build, otherBuild)
	if not d then return { ok = false, error = err } end
	local changes = d.changes
	local skip = { }
	for _, id in ipairs(type(params.skip) == 'table' and params.skip or { }) do skip[tostring(id)] = true end
	if type(params.only) == 'table' and #params.only > 0 then
		local keep = { }
		for _, id in ipairs(params.only) do keep[tostring(id)] = true end
		for _, ch in ipairs(changes) do if not keep[ch.id] then skip[ch.id] = true end end
		for id in pairs(keep) do skip[id] = skip[id] or nil end
	end
	-- Rows that cannot be taken by a respec (another class or ascendancy, a jewel from another build) stay unticked.
	for _, ch in ipairs(changes) do
		if ch.notSimulated or (ch.kind == 'jewel' and not ch.simulated) then skip[ch.id] = true end
	end
	local valid = { }
	for _, ch in ipairs(changes) do valid[ch.id] = true end
	local unknown = { }
	for id in pairs(skip) do if not valid[id] then t_insert(unknown, id) end end
	for _, id in ipairs(type(params.only) == 'table' and params.only or { }) do if not valid[tostring(id)] then t_insert(unknown, tostring(id)) end end

	local calcFunc = build.calcsTab:GetMiscCalculator()
	local scratch = new('PassiveSpec', build, base.treeVersion)
	local function outputFor(state, jewels)
		applyState(scratch, state, jewels)
		return calcFunc({ spec = scratch })
	end
	local all = { }
	for _, ch in ipairs(changes) do all[ch.id] = true end
	local baseState, baseJewels = TreeDiff.state(base, other, changes, all, d.sameBuild)
	local baseOut = outputFor(baseState, baseJewels)
	local baseM = metrics(baseOut)

	-- 1. Each change alone.
	if params.measure ~= false and not d.classDiffers then
		for _, ch in ipairs(changes) do
			if not ch.notSimulated and (ch.kind ~= 'jewel' or ch.simulated) then
				local only = { }
				for id in pairs(all) do if id ~= ch.id then only[id] = true end end
				local state, jewels, intended = TreeDiff.state(base, other, changes, only, d.sameBuild)
				local okC, o = pcall(outputFor, state, jewels)
				if okC and o then
					ch.gain = gainOf(metrics(o), baseM)
					local lost = droppedNames(scratch, intended, scratch)
					if #lost > 0 then ch.dropped = lost end
				end
			end
		end
	end

	-- Order to take them in (best gain per point or Orb of Regret first, dependencies first).
	local function score(ch)
		local g = ch.gain or (params.gains and params.gains[ch.id])
		if not g then return 0 end
		return (g.dpsPct or 0) + (g.ehpPct or 0) + (g.hitPct or 0)
	end
	TreeDiff.order(changes, score)

	-- 2. The ticked set: cost on the scratch spec, then measured for real and rolled back.
	local state, jewels, intended = TreeDiff.state(base, other, changes, skip, d.sameBuild)
	applyState(scratch, state, jewels)
	local plan = TreeDiff.cost(base, scratch)
	local used = scratch:CountAllocNodes()
	local summary = treeSummary()
	plan.pointsBefore = summary.pointsUsed
	plan.pointsUsed = used
	plan.pointsAvailable = summary.pointsAtLevel
	plan.ticked = 0
	for _, ch in ipairs(changes) do if not skip[ch.id] then plan.ticked = plan.ticked + 1 end end
	local dropped = droppedNames(scratch, intended, scratch)

	local before = keyStats(params.fields)
	local beforeCost = costWarnings()
	local mainBefore = build.calcsTab.mainOutput
	local saved = capture()
	local socketsBefore = { }
	for nodeId, slot in pairs(build.itemsTab.sockets or { }) do socketsBefore[nodeId] = slot.selItemId end
	local jewelsBefore = base.jewels
	local okR, rerr = pcall(function()
		applyState(base, state, copyTable(jewels))
		for nodeId, slot in pairs(build.itemsTab.sockets or { }) do
			if jewels[nodeId] ~= nil then slot.selItemId = jewels[nodeId] end
		end
		local o = recalc()
		plan.after = keyStats(params.fields)
		plan.warnings = planWarnings(mainBefore or baseOut, o, beforeCost, dropped)
	end)
	base.jewels = jewelsBefore
	for nodeId, slot in pairs(build.itemsTab.sockets or { }) do slot.selItemId = socketsBefore[nodeId] end
	local errors = restore(saved)
	local check = keyStats(params.fields)
	local rolledBack = #errors == 0
	for k, v in pairs(before) do
		local c = check[k]
		if c == nil or m_abs(c - v) > m_max(m_abs(v) * 1e-6, 1e-6) then rolledBack = false end
	end
	if not okR then return { ok = false, error = 'could not measure the plan: ' .. tostring(rerr), rolledBack = rolledBack } end
	if d.classDiffers then plan.warnings = { { kind = 'class', text = d.note } } end
	plan.before = before
	plan.gain = gainOf(metrics(plan.after), metrics(before))

	-- 3. Keep the ticked set as a new tree (never the player's own).
	local savedSpec
	if type(params.save_as) == 'string' and params.save_as ~= '' then
		local res, serr = Ops.create_spec({ title = params.save_as, copyFrom = build.treeTab.activeSpec, activate = false })
		if not res then return { ok = false, error = serr } end
		local newSpec = build.treeTab.specList[#build.treeTab.specList]
		applyState(newSpec, state, copyTable(jewels))
		newSpec.agentNotes = { }
		for _, ch in ipairs(changes) do
			if not skip[ch.id] then
				for _, id in ipairs(ch.path) do
					local n = TreeDiff.note({ other, base }, id)
					if n then newSpec.agentNotes[id] = n end
				end
			end
		end
		build.modFlag = true
		savedSpec = { index = #build.treeTab.specList, title = newSpec.title }
	end

	-- An unticked new row whose end node a ticked new row still needs (it lies on that path).
	local neededBy = { }
	for _, ch in ipairs(changes) do
		if ch.kind == 'add' and not skip[ch.id] then
			for _, id in ipairs(ch.path) do if id ~= ch.node then neededBy[id] = neededBy[id] or ch.name end end
		end
	end
	-- Plain rows for the caller (no node objects).
	local rows = { }
	for _, ch in ipairs(changes) do
		local note = TreeDiff.note({ other, base }, ch.node)
		t_insert(rows, {
			id = ch.id, kind = ch.kind, node = ch.node, name = ch.name, type = ch.type, points = ch.points, nodes = #ch.path, own = #ch.own,
			ascendancy = ch.ascendancy, effect = ch.effectText, oldEffect = ch.oldText, newEffect = ch.newText, jewel = ch.jewel,
			oldJewel = ch.oldJewel, newJewel = ch.newJewel,
			gain = ch.gain or (params.gains and params.gains[ch.id]), dropped = ch.dropped, note = note, ticked = not skip[ch.id],
			order = ch.order, needs = #ch.needs > 0 and ch.needs or nil, cluster = ch.cluster, notSimulated = (ch.notSimulated or (ch.kind == 'jewel' and not ch.simulated)) or nil,
			tone = TreeDiff.tone(ch.gain or (params.gains and params.gains[ch.id])),
			neededBy = ch.kind == 'add' and skip[ch.id] and neededBy[ch.node] or nil,
		})
	end
	return { ok = true, classDiffers = d.classDiffers, base = { title = base.title or ('Spec ' .. build.treeTab.activeSpec), index = build.treeTab.activeSpec },
		other = { title = title, source = source, index = otherIndex }, sameBuild = d.sameBuild, note = d.note,
		changes = rows, plan = plan, unknownSkip = #unknown > 0 and unknown or nil, rolledBack = rolledBack,
		saved = savedSpec, assumptions = assumptions(), baseline = 'each change alone, against the active tree' }
end

-- edit ops ----------------------------------------------------------------------------
-- One-line notes the AI leaves on nodes of a tree; the Tree tab shows them in the compare labels.
-- Stored on the spec in the build file (<AgentNotes>). notes: { [nodeId] = "text" } ("" removes one).
ops.spec_notes = function(o)
	local tab = build.treeTab
	local index = tonumber(o.spec) or tab.activeSpec
	if o.spec ~= nil and not tonumber(o.spec) then
		for i, s in ipairs(tab.specList) do if (s.title or ''):lower() == tostring(o.spec):lower() then index = i end end
	end
	local spec = tab.specList[index]
	if not spec then return nil, 'no tree ' .. tostring(o.spec) .. ' (1-' .. #tab.specList .. ')' end
	if type(o.notes) ~= 'table' then return nil, 'notes: { [nodeId]: "one line" }' end
	spec.agentNotes = spec.agentNotes or {}
	local set, cleared, errors = 0, 0, {}
	for id, text in pairs(o.notes) do
		local nodeId = tonumber(id)
		if not nodeId or not spec.nodes[nodeId] then t_insert(errors, 'no node ' .. tostring(id))
		elseif tostring(text) == '' then spec.agentNotes[nodeId] = nil cleared = cleared + 1
		else spec.agentNotes[nodeId] = tostring(text):gsub('[%c]+', ' '):sub(1, 120) set = set + 1 end
	end
	if set + cleared == 0 then return nil, table.concat(errors, '; ') end
	build.modFlag = true
	return { spec = index, title = spec.title or ('Spec ' .. index), set = set, cleared = cleared, errors = #errors > 0 and errors or nil }
end


-- Apply changes from another tree into a NEW tree (never the player's own): the ticked set,
-- `only` some change ids, or all but `skip`. o = { compare | xml + source_title (+ spec), only?, skip?, title? }
ops.apply_tree = function(o)
	local title = (type(o.title) == 'string' and o.title ~= '') and o.title or ((build.spec.title or 'Tree') .. ' - applied')
	local res = handlers.tree_plan({ compare = o.compare, xml = o.xml, title = o.source_title, spec = o.spec, only = o.only, skip = o.skip, measure = false, save_as = title })
	if not res or not res.ok then return nil, res and res.error or 'could not apply' end
	if not res.saved then return nil, 'nothing was saved' end
	local applied = { }
	for _, c in ipairs(res.changes) do if c.ticked then t_insert(applied, c.id) end end
	local out = { tree = res.saved.index, title = res.saved.title, applied = applied, regrets = res.plan.regrets, points = res.plan.pointsUsed,
		warnings = nil, unknown = res.unknownSkip }
	if #res.plan.warnings > 0 then
		local w = { }
		for _, x in ipairs(res.plan.warnings) do t_insert(w, x.text) end
		out.warnings = w
	end
	return out
end

-- Make a tree of the loaded build the active one, by number or title (compare { a, b } with a guide stage).
handlers.select_tree = function(params)
	local spec, title = pickSpec(build, params and params.spec)
	if not spec then return { ok = false, error = title } end
	for i, s in ipairs(build.treeTab.specList) do
		if s == spec then build.treeTab:SetActiveSpec(i) end
	end
	recalc()
	return { ok = true, title = title }
end

-- "Point at it" marks (Agent/Marks.lua)
LoadModule("Agent/Handlers/Point", handlers)
