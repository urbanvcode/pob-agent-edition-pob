-- Agent Edition: "point at it" marks for the AI (set_view { view, point: [...] }).
-- Loaded by TreePlan.lua with (handlers). Resolving and storing the marks works in the
-- headless engine too (the tests use it); only the PoB window draws them (Agent/Marks.lua).
local handlers = ...
local Marks = LoadModule("Agent/Marks")

local function plain(m)
	return { n = m.n, kind = m.kind, view = m.view, label = m.label, text = m.text, where = m.where, points = m.points,
		allocated = m.allocated, node = m.node, slot = m.slot, group = m.group, gem = m.gem, var = m.var, line = Marks.Describe(m) }
end

-- params: { marks = { { target, kind?, text? }, ... } } ([] clears them), dry = true: resolve only (headless "where is it").
handlers.point_marks = function(params)
	if not build or not build.spec then return { ok = false, error = 'no build open' } end
	params = params or { }
	local marks = type(params.marks) == 'table' and params.marks or { }
	local list, errors = Marks.Set(build, marks)
	build.agentMarksModule = Marks
	if params.dry then build.agentMarks = nil end
	if #list > 0 and not params.dry then
		local first = list[1]
		build.viewMode = first.view
		if first.kind == 'node' and build.treeTab and build.treeTab.FocusNode then build.treeTab:FocusNode(first.node) end
	end
	local out = { }
	for _, m in ipairs(list) do table.insert(out, plain(m)) end
	return { ok = true, marks = out, errors = #errors > 0 and errors or nil, cleared = #marks == 0 or nil,
		stored = (not params.dry and build.agentMarks and #build.agentMarks) or 0 }
end

-- What is marked now (the tests; the AI after the player dismissed some).
handlers.point_state = function()
	local out = { }
	for _, m in ipairs(build and build.agentMarks or { }) do table.insert(out, plain(m)) end
	return { ok = true, marks = out }
end
