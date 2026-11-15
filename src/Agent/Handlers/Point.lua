-- Agent Edition: "point at it" marks for the AI (set_view { view, point }).
-- Loaded by TreePlan.lua with (handlers). Resolving, simulating and storing the marks works
-- in the headless engine too (the tests use it); only the PoB window draws them (Agent/Marks.lua).
local handlers = ...
local Marks = LoadModule("Agent/Marks")
local t_insert = table.insert

local function plain(m)
	return { n = m.n, kind = m.kind, view = m.view, label = m.label, text = m.text, where = m.where, points = m.points,
		allocated = m.allocated, node = m.node, path = m.path, slot = m.slot, group = m.group, gem = m.gem, var = m.var,
		style = m.style, tone = m.tone, line = m.line, socket = m.socket, to = m.to, toSocket = m.toSocket, toSlot = m.toSlot,
		gain = m.gain, candidate = m.candidate, text_line = Marks.Describe(m) }
end

local function dps(s) return (s.FullDPS and s.FullDPS > 0) and s.FullDPS or (s.CombinedDPS or s.TotalDPS or 0) end
local function weakest(s)
	local low
	for _, t in ipairs({ 'Physical', 'Fire', 'Cold', 'Lightning', 'Chaos' }) do
		local v = s[t .. 'MaximumHitTaken']
		if v and (not low or v < low) then low = v end
	end
	return low or 0
end
local function pct(a, b) return (b and b ~= 0) and (a - b) / math.abs(b) * 100 or 0 end

-- Simulate ops with what_if (always rolled back) for a mark's gain tag.
local function gainOf(ops)
	local res = handlers.what_if({ ops = ops })
	if not res or not res.ok or (res.failed or 0) > 0 then
		local err
		for _, r in ipairs(res and res.results or { }) do if not r.ok then err = r.error end end
		return nil, err or (res and res.error) or 'could not simulate'
	end
	local b, a = res.before, res.after
	local g = { dpsPct = pct(dps(a), dps(b)), ehpPct = pct(a.TotalEHP or 0, b.TotalEHP or 0), hitPct = pct(weakest(a), weakest(b)) }
	g.tag = Marks.GainTag(g)
	g.good = g.dpsPct + g.ehpPct + g.hitPct >= 0
	return g
end

local SHOWN = { { 'TotalEHP', 'EHP' }, { 'Life', 'Life' }, { 'EnergyShield', 'Energy shield' }, { 'FireResist', 'Fire res' }, { 'ColdResist', 'Cold res' },
	{ 'LightningResist', 'Lightning res' }, { 'ChaosResist', 'Chaos res' }, { 'Armour', 'Armour' }, { 'Evasion', 'Evasion' }, { 'Str', 'Str' }, { 'Dex', 'Dex' }, { 'Int', 'Int' } }

-- What a candidate item would replace in the slot, and the stats that change (green better, red worse).
local function candidateOf(m, text)
	local slot = build.itemsTab.slots[m.slot]
	local current = slot and slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId]
	local res = handlers.what_if({ ops = { { op = 'equip', slot = m.slot, text = text } } })
	if not res or not res.ok or (res.failed or 0) > 0 then return nil, 'the candidate item could not be equipped in ' .. m.slot end
	local b, a = res.before, res.after
	local deltas = { }
	local d, db = dps(a), dps(b)
	if math.abs(pct(d, db)) >= 0.05 then t_insert(deltas, { text = string.format('DPS %s%.1f%%', d >= db and '+' or '', pct(d, db)), good = d >= db }) end
	for _, f in ipairs(SHOWN) do
		local x, y = b[f[1]], a[f[1]]
		if x and y and math.abs(y - x) >= 0.5 and #deltas < 7 then
			t_insert(deltas, { text = string.format('%s: %s -> %s', f[2], math.floor(x + 0.5), math.floor(y + 0.5)), good = y >= x })
		end
	end
	local name = text:match('^Rarity: %w+%s*\n([^\n]+)') or text:match('^([^\n]+)')
	return { replaces = current and (current.title or current.name) or 'nothing (empty slot)', name = name, deltas = deltas }
end

-- params: { marks = { { target, kind?, text?, style?, tone?, line?, candidate?, to?, to_slot?, ops? }, ... } ([] clears),
--           tour = bool, again = n (show the n-th latest set again), dry = true: resolve only (no window) }
handlers.point_marks = function(params)
	if not build or not build.spec then return { ok = false, error = 'no build open' } end
	params = params or { }
	build.agentMarksModule = Marks
	local list, errors
	if params.again then
		list, errors = Marks.Again(build, params.again == true and 1 or params.again)
		if not list then return { ok = false, error = errors } end
	else
		local marks = type(params.marks) == 'table' and params.marks or { }
		list, errors = Marks.Set(build, marks, { tour = params.tour == true })
		-- Simulated extras: a gain tag, a candidate item. Kept with the history entry.
		for _, m in ipairs(list) do
			local src = m.source or { }
			if type(src.ops) == 'table' and #src.ops > 0 then
				local g, err = gainOf(src.ops)
				if g then m.gain = g else t_insert(errors, 'gain for ' .. m.label .. ': ' .. tostring(err)) end
			end
			if type(src.candidate) == 'string' and src.candidate ~= '' and m.slot then
				local c, err = candidateOf(m, src.candidate)
				if c then m.candidate = c else t_insert(errors, err) end
			end
		end
	end
	if params.dry then build.agentMarks, build.agentTour = nil, nil end
	if #list > 0 and not params.dry then
		local first = list[1]
		build.viewMode = first.view
		if first.kind == 'node' and build.treeTab and build.treeTab.FocusNode then build.treeTab:FocusNode(first.node) end
	end
	local out = { }
	for _, m in ipairs(list) do t_insert(out, plain(m)) end
	return { ok = true, marks = out, errors = #(errors or { }) > 0 and errors or nil, cleared = (not params.again and #(params.marks or { }) == 0) or nil,
		stored = (not params.dry and build.agentMarks and #build.agentMarks) or 0, tour = build.agentTour and #list or nil }
end

-- What is marked now, the tour step, the history and the reduced-motion setting.
handlers.point_state = function()
	local out, history = { }, { }
	for _, m in ipairs(build and build.agentMarks or { }) do t_insert(out, plain(m)) end
	local h = build and build.agentMarksHistory or { }
	for i = #h, 1, -1 do t_insert(history, { back = #h - i + 1, title = h[i].title, count = h[i].count, tour = h[i].tour }) end
	return { ok = true, marks = out, step = build and build.agentTour and build.agentTour.step or nil, history = history, reducedMotion = Marks.ReducedMotion() }
end

-- Tour step (the box's Next / Back; tests).
handlers.point_step = function(params)
	local step = Marks.Step(build, tonumber(params and params.delta) or 1)
	if not step then return { ok = false, error = 'no tour running' } end
	return { ok = true, step = step, view = build.viewMode }
end
