-- Agent Edition: the Tree tab's respec planner (shown while Compare is ticked).
--
--  * Labels next to every changed node, drawn by PassiveTreeView (compareLabels):
--    NEW / REMOVED / MASTERY CHANGED / JEWEL CHANGED in PoB's compare colours, plus
--    the AI's one-line note on the node (edit { op: "spec_notes" }).
--  * A changes panel beside the tree: respec cost (Orbs of Regret, points), warnings,
--    one row per change with its own simulated gain, a tick box per row (the ticked
--    set is recalculated at once), click a row to centre the tree on it, and
--    "Save as new tree" (a new spec; the player's own tree is never changed).
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

function Panel.new(tab)
	return setmetatable({ tab = tab, skip = { }, scroll = 0, labels = true, shown = true }, Panel)
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

-- What PassiveTreeView draws next to the nodes.
function Panel:LabelData()
	if not self.labels or not self.diff or not self.byNode then return nil end
	return { byNode = self.byNode, specs = { self:Target(), self.tab.build.spec }, colours = Panel.COLOURS, skip = self.skip, draw = Panel.DrawLabels }
end

-- Input and drawing ----------------------------------------------------------------
local function inside(x, y, r) return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h end

local function fmtPct(v)
	if not v or v ~= v then return "?" end
	if math.abs(v) < 0.05 then return "0%" end
	return string.format("%s%.1f%%", v > 0 and "+" or "", v)
end
local function pctColour(v)
	if not v or math.abs(v) < 0.05 then return "^8" end
	return v > 0 and "^x40FF40" or "^xFF5050"
end

local function trim(text, size, width)
	text = tostring(text or "")
	if DrawStringWidth(size, FONT, text) <= width then return text end
	while #text > 1 and DrawStringWidth(size, FONT, text .. "...") > width do text = text:sub(1, -2) end
	return text .. "..."
end

-- Rows in the list: { change, y }; buttons: { label, rect, fn }.
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
	if plan.note then line(plan.note, "^8", 12) end
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
	for _, w in ipairs(p.warnings or { }) do line("! " .. w.text, "^xFF7050", 12) end
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
	button("Save as new tree", function() self:SaveAsNew() end)
	y = y + 28
	self.listTop = y
	local visible = m_max(1, m_floor((rect.y + rect.h - y - 4) / ROW_H))
	self.maxScroll = m_max(0, #(plan.changes or { }) - visible)
	self.scroll = m_min(m_max(self.scroll, 0), self.maxScroll)
	for i = self.scroll + 1, m_min(#plan.changes, self.scroll + visible) do
		t_insert(self.rows, { change = plan.changes[i], rect = { x = rect.x + 4, y = y, w = rect.w - 8, h = ROW_H - 2 } })
		y = y + ROW_H
	end
end

function Panel:SaveAsNew()
	local base = self.tab.build.spec
	local title = (base.title or "Tree") .. " - plan"
	local res = self:Refresh(false, { save_as = title })
	if res and res.ok and res.saved then
		self.message = "Saved as tree " .. res.saved.index .. ": " .. res.saved.title .. " (your tree is unchanged; Ctrl+S keeps it in the file)"
	end
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
					if cx < r.rect.x + 24 then
						self:SetTicked(r.change.id, self.skip[r.change.id] and true or false)
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
	for _, b in ipairs(self.buttons or { }) do
		local hover = inside(cx, cy, b.rect)
		box(b.rect, hover and (Theme.btnFillHover or { 0.15, 0.17, 0.22 }) or (Theme.btnFill or { 0.1, 0.12, 0.15 }), Theme.btnBorder or { 0.24, 0.27, 0.34 })
		DrawString(b.rect.x + 8, b.rect.y + 3, "LEFT", 14, FONT, "^7" .. b.label)
	end
	if #self.plan.changes == 0 then DrawString(rect.x + 8, self.listTop, "LEFT", 14, FONT, "^8The trees are the same.") end
	for _, r in ipairs(self.rows or { }) do
		local c = r.change
		local col = Panel.COLOURS[c.kind] or Panel.COLOURS.jewel
		local ticked = not self.skip[c.id]
		if inside(cx, cy, r.rect) then
			SetDrawColor(0.12, 0.14, 0.18)
			DrawImage(nil, r.rect.x, r.rect.y, r.rect.w, r.rect.h)
		end
		-- tick box
		local tb = { x = r.rect.x + 4, y = r.rect.y + 8, w = 16, h = 16 }
		box(tb, { 0.05, 0.06, 0.08 }, ticked and { col[1], col[2], col[3] } or { 0.35, 0.35, 0.4 })
		if ticked then SetDrawColor(col[1], col[2], col[3]) DrawImage(nil, tb.x + 4, tb.y + 4, 8, 8) end
		local tag = TreeDiff.tag(c)
		local name = c.name
		if c.kind == "mastery" then name = name .. ": " .. tostring(c.newEffect) end
		local textX = r.rect.x + 26
		local w = r.rect.w - 30
		DrawString(textX, r.rect.y + 2, "LEFT", 14, FONT, trim((ticked and col[4] or "^8") .. tag .. " ^7" .. name .. (c.points and c.points ~= 0 and string.format(" ^8(%+d)", c.points) or ""), 14, w))
		local g = c.gain
		local second
		if c.notSimulated then second = "^8jewel from the other build: not simulated"
		elseif g then second = string.format("DPS %s%s^7  EHP %s%s^7  Max hit %s%s", pctColour(g.dpsPct), fmtPct(g.dpsPct), pctColour(g.ehpPct), fmtPct(g.ehpPct), pctColour(g.hitPct), fmtPct(g.hitPct))
		else second = "^8measuring..." end
		if c.neededBy then second = "^xE0C060still taken: " .. c.neededBy .. " needs it  ^7" .. second end
		if c.note then second = second .. "  ^x9FB8D0" .. c.note end
		DrawString(textX, r.rect.y + 18, "LEFT", 12, FONT, trim(second, 12, w))
	end
	if (self.maxScroll or 0) > 0 then
		DrawString(rect.x + rect.w - 8, rect.y + rect.h - 16, "RIGHT", 12, FONT, string.format("^8%d-%d of %d (scroll)", self.scroll + 1, m_min(#self.plan.changes, self.scroll + #self.rows), #self.plan.changes))
	end
end

-- Labels on the tree: called by PassiveTreeView:Draw with its coordinate function.
-- Boxes are placed greedily (notables, keystones and masteries first) beside the node,
-- trying right, left, above and below; a small passive's box is skipped when it would
-- overlap, so the view stays readable at any zoom.
local PRIORITY = { Keystone = 1, Notable = 2, Mastery = 2, Socket = 2 }
function Panel.DrawLabels(data, spec, compareSpec, treeToScreen, scale, viewPort)
	local items = { }
	for id, entry in pairs(data.byNode) do
		local node = spec.nodes[id] or compareSpec.nodes[id]
		if node and node.x and node.y then
			local sx, sy = treeToScreen(node.x, node.y)
			if sx > viewPort.x - 50 and sx < viewPort.x + viewPort.width + 50 and sy > viewPort.y - 30 and sy < viewPort.y + viewPort.height + 30 then
				local c = entry.change
				local important = PRIORITY[node.type] or (node.ascendancyName and node.isNotable)
				local prio = (PRIORITY[node.type] or (important and 2) or 4) - (entry.isEnd and 0.5 or 0)
				t_insert(items, { node = node, change = c, sx = sx, sy = sy, prio = prio, important = important and true or false })
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
		local c, node = it.change, it.node
		local col = data.colours[c.kind] or data.colours.jewel
		local tag = TreeDiff.tag(c)
		local line1
		if c.kind == "mastery" then
			line1 = tag .. ": " .. trim(c.oldText, size, 150) .. " -> " .. trim(c.newText, size, 150)
		elseif c.kind == "jewel" then
			line1 = tag .. ": " .. trim(c.oldJewel, size, 140) .. " -> " .. trim(c.newJewel, size, 140)
		elseif it.important then
			line1 = tag .. " " .. trim(node.dn or node.name, size, 200)
			if node.type == "Mastery" and c.effectText and c.node == node.id then line1 = line1 .. ": " .. trim(c.effectText, size, 180) end
		else
			line1 = tag
		end
		local note = TreeDiff.note(data.specs, node.id)
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
			local skipped = data.skip and data.skip[c.id]
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
