-- Agent Edition: the Tree tab's respec planner (shown while Compare is ticked).
--
--  * Labels next to every changed node, drawn by PassiveTreeView (compareLabels):
--    NEW / REMOVED / MASTERY CHANGED / JEWEL CHANGED in PoB's compare colours, plus
--    the AI's one-line note on the node (edit { op: "spec_notes" }).
--  * A changes panel beside the tree: respec cost (Orbs of Regret, points), warnings,
--    one row per change with its own simulated gain, a tick box per row (the ticked
--    set is recalculated at once), click a row to centre the tree on it, and
--    "Apply" buttons (one change, the ticked ones, all) that write a NEW tree: the
--    player's own tree is never changed. Rows are numbered in the order to take them
--    (best gain per point first, after what they need); nodes and boxes can be coloured
--    by gain (green damage, blue defence, red loss) with a legend; hovering a changed
--    node shows what changed, the AI's note and its own simulated gain.
-- Numbers come from the agent handler tree_plan (Agent/Handlers/TreePlan.lua), the
-- same one agent-mcp's compare { tree } calls.
local TreeDiff = LoadModule("Agent/TreeDiff")
local Theme = LoadModule("Agent/Theme")
local t_insert = table.insert
local m_max, m_min, m_floor = math.max, math.min, math.floor

local Panel = { }
Panel.__index = Panel

Panel.WIDTH = 390
local ROW_H = 36
local FONT = "VAR"

-- PoB's compare colours (PassiveTreeView:GetCompareNodeColor): green = only in the compared
-- tree (new), red = only in the active tree (removed), blue = mastery or jewel changed.
Panel.COLOURS = {
	add = { 0.25, 1, 0.25, "^x40FF40" },
	remove = { 1, 0.25, 0.25, "^xFF5050" },
	mastery = { 0.35, 0.55, 1, "^x7090FF" },
	jewel = { 0.35, 0.55, 1, "^x7090FF" },
}

-- Gain colours (the default; the "Gain colours" box falls back to PoB's own):
-- damage gain green, defence gain blue, loss red, no measured change grey.
Panel.TONES = {
	damage = { 0.25, 1, 0.25, "^x40FF40", "damage gain" },
	defence = { 0.35, 0.65, 1, "^x60A0FF", "defence gain" },
	loss = { 1, 0.25, 0.25, "^xFF5050", "loss" },
	none = { 0.6, 0.6, 0.6, "^x999999", "no change" },
}

function Panel.new(tab)
	return setmetatable({ tab = tab, skip = { }, scroll = 0, labels = true, shown = true, gainColours = true }, Panel)
end

-- Colour of a change: by its gain (shaded by size), else PoB's compare colour for its kind.
function Panel.ColourOf(row, kind, gainColours)
	if gainColours and row and row.tone then
		local t = Panel.TONES[row.tone.kind] or Panel.TONES.none
		local k = row.tone.kind == "none" and 1 or row.tone.strength
		local grey = 0.35
		return { grey + (t[1] - grey) * k, grey + (t[2] - grey) * k, grey + (t[3] - grey) * k, t[4] }
	end
	return Panel.COLOURS[kind] or Panel.COLOURS.jewel
end

-- The legend shown at the top of the panel (and checked by the tests).
function Panel.Legend(gainColours)
	if not gainColours then return "^7Colours: ^x40FF40new ^xFF5050removed ^x7090FFmastery/jewel ^8(PoB's compare colours)" end
	local parts = { "^7Colours:" }
	for _, k in ipairs({ "damage", "defence", "loss", "none" }) do t_insert(parts, Panel.TONES[k][4] .. Panel.TONES[k][5]) end
	return table.concat(parts, " ") .. " ^8(brighter = bigger)"
end

local function handlers()
	local server = launch and launch.agentServer
	return server and server.handlers
end

-- Changes only when either tree (or its jewels and masteries) changes.
local function signature(spec)
	if not spec then return "-" end
	local n, sum, m = 0, 0, 0
	for id in pairs(spec.allocNodes) do n = n + 1 sum = sum + id end
	for id, e in pairs(spec.masterySelections) do m = m + id * 7 + e end
	for id, item in pairs(spec.jewels or { }) do m = m + id * 3 + (item or 0) end
	return n .. ":" .. sum .. ":" .. m
end

function Panel:Target()
	local tab = self.tab
	if not tab.isComparing then return nil end
	return tab:CompareSpecObj()
end

-- Diff for the labels (pure, cheap) and the measured plan (debounced while the tree is edited).
function Panel:Update()
	local tab = self.tab
	local other = self:Target()
	local base = tab.build.spec
	if not other or other == base then
		self.diff, self.plan, self.key = nil, nil, nil
		return
	end
	local key = tostring(other) .. "|" .. tostring(base) .. "|" .. signature(base) .. "|" .. signature(other)
	if key ~= self.key then
		local otherBuild = other.build ~= tab.build and other.build or nil
		local d, err = TreeDiff.diff(base, other, tab.build, otherBuild)
		self.diff, self.error = d, err
		self.byNode = d and TreeDiff.nodeIndex(d.changes) or nil
		if tostring(other) ~= self.target then self.skip = { } self.scroll = 0 self.message = nil end
		self.target = tostring(other)
		self.key = key
		self.dueAt = (GetTime and GetTime() or 0) + (self.plan and 400 or 0)
		self.measured = false
	end
	if self.diff and not self.measured and (GetTime and GetTime() or 0) >= (self.dueAt or 0) then
		self:Refresh(true)
	end
end

function Panel:Params(extra)
	local other = self:Target()
	local skip = { }
	for id in pairs(self.skip) do t_insert(skip, id) end
	local p = { otherSpec = other, otherBuild = other and other.build ~= self.tab.build and other.build or nil,
		title = self.tab:CompareTitle(), skip = skip, measure = true }
	-- Keep each change's own gain for the order and the colours when only the ticked set is recalculated.
	if self.plan then
		p.gains = { }
		for _, c in ipairs(self.plan.changes or { }) do p.gains[c.id] = c.gain end
	end
	for k, v in pairs(extra or { }) do p[k] = v end
	return p
end

-- measure = true: every change alone as well (new trees); false: only the ticked set.
function Panel:Refresh(measure, extra)
	local h = handlers()
	self.measured = true
	if not h or not h.tree_plan or not h._withBuild then
		self.error = "The planner needs the Agent server (it is off in this window)."
		return nil
	end
	local params = self:Params(extra)
	params.measure = measure
	local res = h._withBuild(self.tab.build, h.tree_plan, params)
	if not res or not res.ok then
		self.error = res and res.error or "the plan could not be calculated"
		return res
	end
	self.error = nil
	if not measure and self.plan then
		-- Keep each change's own gain from the full run.
		local old = { }
		for _, c in ipairs(self.plan.changes or { }) do old[c.id] = c end
		for _, c in ipairs(res.changes or { }) do if old[c.id] then c.gain, c.dropped = old[c.id].gain, old[c.id].dropped end end
	end
	self.plan = res
	return res
end

function Panel:SetTicked(id, ticked)
	self.skip[id] = (not ticked) or nil
	self:Refresh(false)
end

function Panel:SetAll(ticked)
	self.skip = { }
	if not ticked then for _, c in ipairs(self.plan and self.plan.changes or { }) do self.skip[c.id] = true end end
	self:Refresh(false)
end


local function fmtPct(v)
	if not v or v ~= v then return "?" end
	if math.abs(v) < 0.05 then return "0%" end
	return string.format("%s%.1f%%", v > 0 and "+" or "", v)
end
local function pctColour(v)
	if not v or math.abs(v) < 0.05 then return "^8" end
	return v > 0 and "^x40FF40" or "^xFF5050"
end

-- What PassiveTreeView draws next to the nodes, colours the nodes with and adds to tooltips.
function Panel:LabelData()
	if not self.diff or not self.byNode then return nil end
	local rows = { }
	for _, c in ipairs(self.plan and self.plan.changes or { }) do rows[c.id] = c end
	return { byNode = self.byNode, rows = rows, specs = { self:Target(), self.tab.build.spec }, colours = Panel.COLOURS, skip = self.skip,
		showBoxes = self.labels, gainColours = self.gainColours,
		draw = Panel.DrawLabels, tooltip = Panel.AddTooltip, nodeColour = Panel.NodeColour }
end

-- Node colour on the tree (PassiveTreeView:GetCompareNodeColor): by gain when switched on.
function Panel.NodeColour(data, nodeId)
	if not data.gainColours then return nil end
	local entry = data.byNode[nodeId]
	local row = entry and data.rows[entry.change.id]
	if not row or not row.tone then return nil end
	local c = Panel.ColourOf(row, row.kind, true)
	return c[1], c[2], c[3]
end

-- Hover lines for a changed node: what changed, the AI's note, its own simulated gain.
function Panel.TooltipLines(data, nodeId)
	local entry = data.byNode[nodeId]
	if not entry then return nil end
	local c = entry.change
	local row = data.rows[c.id] or { }
	local L = { }
	local what = TreeDiff.tag({ kind = c.kind, cluster = c.cluster, order = row.order }) .. " " .. tostring(c.name)
	if not entry.isEnd then what = what .. " (on the path to it)" end
	t_insert(L, "^xE0C060AI plan: ^7" .. what .. ((data.skip and data.skip[c.id]) and " ^8(unticked)" or ""))
	if c.kind == "mastery" then t_insert(L, "^7" .. tostring(c.oldText) .. " ^8->^7 " .. tostring(c.newText)) end
	if c.kind == "jewel" then t_insert(L, "^7" .. tostring(c.oldJewel) .. " ^8->^7 " .. tostring(c.newJewel)) end
	if c.jewel then t_insert(L, "^7Jewel: " .. c.jewel) end
	local note = TreeDiff.note(data.specs, c.node)
	if note then t_insert(L, "^x9FB8D0Why: " .. note) end
	local g = row.gain
	if g then t_insert(L, string.format("^7Its own gain: DPS %s%s^7 | EHP %s%s^7 | weakest max hit %s%s", pctColour(g.dpsPct), fmtPct(g.dpsPct), pctColour(g.ehpPct), fmtPct(g.ehpPct), pctColour(g.hitPct), fmtPct(g.hitPct)))
	elseif row.notSimulated then t_insert(L, "^8Not simulated (another class, ascendancy or build's jewel)") end
	if row.needs then t_insert(L, "^8Take after: " .. table.concat(row.needs, ", ")) end
	return L
end

function Panel.AddTooltip(data, tooltip, nodeId)
	local L = Panel.TooltipLines(data, nodeId)
	if not L then return end
	tooltip:AddSeparator(10)
	for _, l in ipairs(L) do tooltip:AddLine(16, l) end
end

-- Input and drawing ----------------------------------------------------------------
local function inside(x, y, r) return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end

local function trim(text, size, width)
	text = tostring(text or "")
	if DrawStringWidth(size, FONT, text) <= width then return text end
	while #text > 1 and DrawStringWidth(size, FONT, text .. "...") > width do text = text:sub(1, -2) end
	return text .. "..."
end

-- Rows in the list (in the order to take them); buttons: { label, rect, fn }.
function Panel:Layout(rect)
	self.rect = rect
	self.buttons, self.rows = { }, { }
	local plan = self.plan
	if not plan then return end
	local y = rect.y + 8
	self.header = { }
	local function line(text, colour, size)
		for _, l in ipairs(main:WrapString(text, size or 14, rect.w - 16)) do
			t_insert(self.header, { y = y, text = (colour or "^7") .. l, size = size or 14 })
			y = y + (size or 14) + 2
		end
	end
	line("Respec plan", "^7", 18)
	line("vs " .. tostring(plan.other.title), "^8", 14)
	if plan.note then line(plan.note, plan.classDiffers and "^xFF7050" or "^8", 12) end
	y = y + 4
	local p = plan.plan or { }
	line(string.format("Orbs of Regret: %d    Points: %d -> %d of %d", p.regrets or 0, p.pointsBefore or 0, p.pointsUsed or 0, p.pointsAvailable or 0),
		(p.pointsUsed or 0) > (p.pointsAvailable or 0) and "^xFF5050" or "^7")
	if (p.masterySwaps or 0) > 0 or (p.ascRefunded or 0) > 0 then
		line(string.format("Mastery swaps: %d   Ascendancy refunds: %d (not priced)", p.masterySwaps or 0, p.ascRefunded or 0), "^8", 12)
	end
	local g = p.gain or { }
	line(string.format("Ticked %d of %d:  DPS %s%s^7  EHP %s%s^7  Max hit %s%s", p.ticked or 0, #(plan.changes or { }),
		pctColour(g.dpsPct), fmtPct(g.dpsPct), pctColour(g.ehpPct), fmtPct(g.ehpPct), pctColour(g.hitPct), fmtPct(g.hitPct)))
	for _, w in ipairs(p.warnings or { }) do if w.kind ~= "class" then line("! " .. w.text, "^xFF7050", 12) end end
	line(Panel.Legend(self.gainColours), "^7", 12)
	if self.message then line(self.message, "^x40FF40", 12) end
	y = y + 4
	local bx = rect.x + 8
	local function button(label, fn)
		local w = DrawStringWidth(14, FONT, label) + 16
		t_insert(self.buttons, { label = label, rect = { x = bx, y = y, w = w, h = 20 }, fn = fn })
		bx = bx + w + 6
	end
	button("All", function() self:SetAll(true) end)
	button("None", function() self:SetAll(false) end)
	button("Apply ticked", function() self:Apply(nil) end)
	button("Apply all", function() self:Apply("all") end)
	button(self.gainColours and "PoB colours" or "Gain colours", function() self.gainColours = not self.gainColours end)
	y = y + 28
	self.listTop = y
	local ordered = { }
	for _, c in ipairs(plan.changes or { }) do t_insert(ordered, c) end
	table.sort(ordered, function(a, b) return (a.order or 1e9) < (b.order or 1e9) end)
	self.ordered = ordered
	local visible = m_max(1, m_floor((rect.y + rect.h - y - 4) / ROW_H))
	self.maxScroll = m_max(0, #ordered - visible)
	self.scroll = m_min(m_max(self.scroll, 0), self.maxScroll)
	for i = self.scroll + 1, m_min(#ordered, self.scroll + visible) do
		local r = { x = rect.x + 4, y = y, w = rect.w - 8, h = ROW_H - 2 }
		t_insert(self.rows, { change = ordered[i], rect = r, apply = { x = r.x + r.w - 50, y = r.y + 7, w = 46, h = 18 } })
		y = y + ROW_H
	end
end

-- Apply into a NEW tree (the player's own tree is never changed): one change id, "all", or nil = the ticked ones.
function Panel:Apply(what)
	local base = self.tab.build.spec
	local h = handlers()
	if not h or not h.tree_plan then return nil end
	local params = self:Params({ measure = false })
	local name
	if what == "all" then
		params.skip = { }
		name = (base.title or "Tree") .. " - all applied"
	elseif what then
		params.only = { what }
		local c
		for _, x in ipairs(self.plan and self.plan.changes or { }) do if x.id == what then c = x end end
		name = (base.title or "Tree") .. " + " .. (c and c.name or what)
	else
		name = (base.title or "Tree") .. " - plan"
	end
	params.save_as = name
	local res = h._withBuild(self.tab.build, h.tree_plan, params)
	if res and res.ok and res.saved then
		self.message = "Applied into a new tree " .. res.saved.index .. ": " .. res.saved.title .. " (your tree is unchanged; Ctrl+S keeps it in the file)"
	else
		self.message = "Could not apply: " .. tostring(res and res.error)
	end
	self:Refresh(false)
	return res
end

function Panel:HandleInput(inputEvents)
	local rect = self.rect
	if not rect then return end
	local cx, cy = GetCursorPos()
	if not inside(cx, cy, rect) then return end
	for id, event in ipairs(inputEvents) do
		if event.type == "KeyUp" and event.key == "LEFTBUTTON" then
			for _, b in ipairs(self.buttons or { }) do
				if inside(cx, cy, b.rect) then b.fn() end
			end
			for _, r in ipairs(self.rows or { }) do
				if inside(cx, cy, r.rect) then
					if inside(cx, cy, r.apply) then
						if not r.change.notSimulated then self:Apply(r.change.id) end
					elseif cx < r.rect.x + 24 then
						if not r.change.notSimulated then self:SetTicked(r.change.id, self.skip[r.change.id] and true or false) end
					else
						self.tab:FocusNode(r.change.node)
					end
				end
			end
			inputEvents[id] = nil
		elseif event.type == "KeyDown" and event.key == "LEFTBUTTON" then
			inputEvents[id] = nil
		elseif event.type == "KeyUp" and (event.key == "WHEELUP" or event.key == "WHEELDOWN") then
			self.scroll = self.scroll + (event.key == "WHEELUP" and -2 or 2)
			inputEvents[id] = nil
		end
	end
end

local function box(r, fill, border)
	SetDrawColor(border[1], border[2], border[3])
	DrawImage(nil, r.x, r.y, r.w, r.h)
	SetDrawColor(fill[1], fill[2], fill[3])
	DrawImage(nil, r.x + 1, r.y + 1, r.w - 2, r.h - 2)
end

-- The first line of a change, as the list shows it.
local function changeLine(c)
	local name = c.name
	if c.kind == "mastery" then name = name .. ": " .. tostring(c.newEffect or c.newText)
	elseif c.kind == "jewel" then name = name .. ": " .. tostring(c.oldJewel) .. " -> " .. tostring(c.newJewel)
	elseif c.jewel then name = name .. " (" .. c.jewel .. ")" end
	return name
end
Panel.changeLine = changeLine

function Panel:Draw()
	local rect = self.rect
	if not rect then return end
	SetDrawLayer(1)
	box(rect, Theme.panel or { 0.06, 0.07, 0.09 }, Theme.divider or { 0.2, 0.2, 0.25 })
	if not self.plan then
		local text = self.error and ("^xFF7050" .. self.error) or (self.diff and #self.diff.changes == 0 and "^8The trees are the same.") or "^8Calculating the plan..."
		local y = rect.y + 10
		for _, l in ipairs(main:WrapString(text, 14, rect.w - 16)) do DrawString(rect.x + 8, y, "LEFT", 14, FONT, l) y = y + 16 end
		return
	end
	for _, h in ipairs(self.header or { }) do DrawString(rect.x + 8, h.y, "LEFT", h.size, h.size >= 18 and "VAR BOLD" or FONT, h.text) end
	local cx, cy = GetCursorPos()
	local function button(r, label, enabled)
		local hover = enabled and inside(cx, cy, r)
		box(r, hover and (Theme.btnFillHover or { 0.15, 0.17, 0.22 }) or (Theme.btnFill or { 0.1, 0.12, 0.15 }), Theme.btnBorder or { 0.24, 0.27, 0.34 })
		DrawString(r.x + r.w / 2, r.y + (r.h - 14) / 2, "CENTER_X", 14, FONT, (enabled and "^7" or "^8") .. label)
	end
	for _, b in ipairs(self.buttons or { }) do button(b.rect, b.label, true) end
	if #self.plan.changes == 0 then DrawString(rect.x + 8, self.listTop, "LEFT", 14, FONT, "^8The trees are the same.") end
	for _, r in ipairs(self.rows or { }) do
		local c = r.change
		local col = Panel.ColourOf(c, c.kind, self.gainColours)
		local ticked = not self.skip[c.id] and not c.notSimulated
		if inside(cx, cy, r.rect) then
			SetDrawColor(0.12, 0.14, 0.18)
			DrawImage(nil, r.rect.x, r.rect.y, r.rect.w, r.rect.h)
		end
		local tb = { x = r.rect.x + 4, y = r.rect.y + 8, w = 16, h = 16 }
		box(tb, { 0.05, 0.06, 0.08 }, ticked and { col[1], col[2], col[3] } or { 0.35, 0.35, 0.4 })
		if ticked then SetDrawColor(col[1], col[2], col[3]) DrawImage(nil, tb.x + 4, tb.y + 4, 8, 8) end
		local textX = r.rect.x + 26
		local w = r.rect.w - 30 - 54
		DrawString(textX, r.rect.y + 2, "LEFT", 14, FONT, trim((ticked and col[4] or "^8") .. TreeDiff.tag(c) .. " ^7" .. changeLine(c) .. (c.points and c.points ~= 0 and string.format(" ^8(%+d)", c.points) or ""), 14, w))
		local g = c.gain
		local second
		if c.notSimulated then second = "^8not simulated (another class, ascendancy or build's jewel)"
		elseif g then second = string.format("DPS %s%s^7  EHP %s%s^7  Max hit %s%s", pctColour(g.dpsPct), fmtPct(g.dpsPct), pctColour(g.ehpPct), fmtPct(g.ehpPct), pctColour(g.hitPct), fmtPct(g.hitPct))
		else second = "^8measuring..." end
		if c.neededBy then second = "^xE0C060still taken: " .. c.neededBy .. " needs it  ^7" .. second end
		if c.note then second = second .. "  ^x9FB8D0" .. c.note end
		DrawString(textX, r.rect.y + 18, "LEFT", 12, FONT, trim(second, 12, w))
		button(r.apply, "Apply", not c.notSimulated)
	end
	if (self.maxScroll or 0) > 0 then
		DrawString(rect.x + rect.w - 8, rect.y + rect.h - 16, "RIGHT", 12, FONT, string.format("^8%d-%d of %d (scroll)", self.scroll + 1, m_min(#self.ordered, self.scroll + #self.rows), #self.ordered))
	end
end

-- Labels on the tree: called by PassiveTreeView:Draw with its coordinate function.
-- Boxes are placed greedily (notables, keystones and masteries first) beside the node,
-- trying right, left, above and below; a small passive's box is skipped when it would
-- overlap, so the view stays readable at any zoom.
local PRIORITY = { Keystone = 1, Notable = 2, Mastery = 2, Socket = 2 }

-- The text of a node's box (also used by the tests).
function Panel.LabelText(data, node, entry)
	local c = entry.change
	local row = data.rows and data.rows[c.id] or { }
	local tag = TreeDiff.tag({ kind = c.kind, cluster = c.cluster, order = entry.isEnd and row.order or nil })
	local important = PRIORITY[node.type] or (node.ascendancyName and node.isNotable)
	if c.kind == "mastery" then
		return tag .. ": " .. trim(c.oldText, 14, 150) .. " -> " .. trim(c.newText, 14, 150)
	elseif c.kind == "jewel" then
		return tag .. ": " .. trim(c.oldJewel, 14, 140) .. " -> " .. trim(c.newJewel, 14, 140)
	elseif important then
		local text = tag .. " " .. trim(node.dn or node.name, 14, 200)
		if node.type == "Mastery" and c.effectText and c.node == node.id then text = text .. ": " .. trim(c.effectText, 14, 180) end
		if node.type == "Socket" and c.jewel and c.node == node.id then text = text .. ": " .. trim(c.jewel, 14, 160) end
		return text
	end
	return tag
end

function Panel.DrawLabels(data, spec, compareSpec, treeToScreen, scale, viewPort)
	if not data.showBoxes then return end
	local items = { }
	for id, entry in pairs(data.byNode) do
		local node = spec.nodes[id] or compareSpec.nodes[id]
		if node and node.x and node.y then
			local sx, sy = treeToScreen(node.x, node.y)
			if sx > viewPort.x - 50 and sx < viewPort.x + viewPort.width + 50 and sy > viewPort.y - 30 and sy < viewPort.y + viewPort.height + 30 then
				local important = PRIORITY[node.type] or (node.ascendancyName and node.isNotable)
				local prio = (PRIORITY[node.type] or (important and 2) or 4) - (entry.isEnd and 0.5 or 0)
				t_insert(items, { node = node, entry = entry, sx = sx, sy = sy, prio = prio })
			end
		end
	end
	table.sort(items, function(a, b) if a.prio ~= b.prio then return a.prio < b.prio end return a.node.id < b.node.id end)
	local placed = { }
	local function overlaps(r)
		if r.x < viewPort.x or r.y < viewPort.y or r.x + r.w > viewPort.x + viewPort.width or r.y + r.h > viewPort.y + viewPort.height then return true end
		for _, o in ipairs(placed) do
			if r.x < o.x + o.w + 2 and o.x < r.x + r.w + 2 and r.y < o.y + o.h + 2 and o.y < r.y + r.h + 2 then return true end
		end
	end
	SetDrawLayer(nil, 30)
	local size, noteSize = 14, 12
	for _, it in ipairs(items) do
		local c, node = it.entry.change, it.node
		local row = data.rows and data.rows[c.id]
		local col = Panel.ColourOf(row, c.kind, data.gainColours)
		local line1 = Panel.LabelText(data, node, it.entry)
		local note = it.entry.isEnd and TreeDiff.note(data.specs, node.id) or nil
		local w = DrawStringWidth(size, FONT, line1) + 10
		if note then note = trim(note, noteSize, 260) w = m_max(w, DrawStringWidth(noteSize, FONT, note) + 10) end
		local h = size + 6 + (note and noteSize + 2 or 0)
		local radius = m_max(8, (node.size or 40) * scale * 0.6)
		local tries = {
			{ it.sx + radius + 4, it.sy - h / 2 }, { it.sx - radius - 4 - w, it.sy - h / 2 },
			{ it.sx - w / 2, it.sy - radius - 4 - h }, { it.sx - w / 2, it.sy + radius + 4 },
			{ it.sx + radius + 4, it.sy - h - 4 }, { it.sx + radius + 4, it.sy + 4 },
		}
		local spot
		for _, t in ipairs(tries) do
			local r = { x = m_floor(t[1]), y = m_floor(t[2]), w = w, h = h }
			if not overlaps(r) then spot = r break end
		end
		if spot then
			t_insert(placed, spot)
			local skipped = (data.skip and data.skip[c.id]) or (row and row.notSimulated)
			local a = skipped and 0.45 or 1
			SetDrawColor(col[1] * a, col[2] * a, col[3] * a)
			DrawImage(nil, spot.x, spot.y, spot.w, spot.h)
			SetDrawColor(0.04, 0.045, 0.06, 0.92)
			DrawImage(nil, spot.x + 1, spot.y + 1, spot.w - 2, spot.h - 2)
			DrawString(spot.x + 5, spot.y + 3, "LEFT", size, FONT, (skipped and "^8" or col[4]) .. line1)
			if note then DrawString(spot.x + 5, spot.y + size + 5, "LEFT", noteSize, FONT, "^x9FB8D0" .. note) end
		end
	end
	SetDrawColor(1, 1, 1)
end

return Panel
