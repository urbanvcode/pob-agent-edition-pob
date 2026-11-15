-- Agent Edition: "point at it" marks.
--
-- The AI points at things the player can't find (set_view { view, point: [...] }):
-- a passive node, notable, mastery (also by one of its effects) or jewel socket on the
-- tree; an item slot or flask on the Items tab; a skill group or gem on the Skills tab;
-- a Configuration option; a Calcs row. Each mark is numbered (1, 2, 3 for step-by-step
-- help), drawn as a pulsing outline with a labelled box, and stays until the player
-- clicks it away, presses "Clear AI marks", or the AI clears them (point: []).
-- Marks live in memory only (build.agentMarks): never saved into the build file.
-- Drawing only: nothing here focuses or raises the PoB window.
local t_insert = table.insert
local m_floor, m_max, m_min, m_abs = math.floor, math.max, math.min, math.abs

local Marks = { }

local function lower(s) return tostring(s or ""):lower() end
local function strip(s) return (tostring(s or ""):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", "")) end

-- Best match by name: exact first, then "starts with", then "contains".
local function best(list, want, nameOf)
	local w = lower(want)
	local exact, starts, contains
	for _, x in ipairs(list) do
		local n = lower(nameOf(x))
		if n == w then exact = exact or x
		elseif n:sub(1, #w) == w then starts = starts or x
		elseif n:find(w, 1, true) then contains = contains or x end
	end
	return exact or starts or contains
end

-- Tree: a node by id, by name (closest to the allocated tree when names repeat, as
-- masteries do), or a mastery by one of its effects ("Lucky").
local function resolveNode(build, want, kind)
	local spec = build.spec
	local id = tonumber(want)
	if id and spec.nodes[id] then return spec.nodes[id] end
	local w = lower(want)
	local candidates = { }
	for _, node in pairs(spec.nodes) do
		local name = lower(node.dn or node.name)
		if name ~= "" and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and (not node.ascendancyName or node.ascendancyName == spec.curAscendClassName) then
			local score
			if name == w then score = 0 elseif name:find(w, 1, true) then score = 1 end
			if not score and node.type == "Mastery" and kind ~= "slot" then
				for _, e in ipairs(node.masteryEffects or { }) do
					local effect = spec.tree.masteryEffects and spec.tree.masteryEffects[e.effect]
					if effect and lower(table.concat(effect.sd or { }, " ")):find(w, 1, true) then score = 2 node._markEffect = table.concat(effect.sd, " / ") break end
				end
			end
			if score then t_insert(candidates, { node = node, score = score, dist = node.alloc and 0 or (node.pathDist or 999) }) end
		end
	end
	table.sort(candidates, function(a, b)
		if a.score ~= b.score then return a.score < b.score end
		if a.dist ~= b.dist then return a.dist < b.dist end
		return a.node.id < b.node.id
	end)
	return candidates[1] and candidates[1].node
end

local SLOT_ALIASES = { ["body"] = "Body Armour", ["chest"] = "Body Armour", ["weapon"] = "Weapon 1", ["main hand"] = "Weapon 1",
	["off hand"] = "Weapon 2", ["offhand"] = "Weapon 2", ["shield"] = "Weapon 2", ["quiver"] = "Weapon 2", ["ring"] = "Ring 1", ["helm"] = "Helmet" }

local function resolveSlot(build, want)
	local w = lower(want)
	local name = SLOT_ALIASES[w] or want
	for slotName, slot in pairs(build.itemsTab.slots) do
		if lower(slotName) == lower(name) then return slotName, slot end
	end
	local flask = w:match("^flask%s*(%d)$")
	if flask then return "Flask " .. flask, build.itemsTab.slots["Flask " .. flask] end
	-- An item by name: the slot it is equipped in.
	for slotName, slot in pairs(build.itemsTab.slots) do
		local item = slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId]
		if item and not slot.nodeId and (lower(item.title or item.name):find(w, 1, true) or lower(item.baseName):find(w, 1, true)) then return slotName, slot end
	end
end

local function resolveGem(build, want)
	local w = lower(want)
	local groups = build.skillsTab and build.skillsTab.socketGroupList or { }
	for gi, g in ipairs(groups) do
		for ji, gem in ipairs(g.gemList or { }) do
			if lower(gem.nameSpec) == w or lower(gem.grantedEffect and gem.grantedEffect.name) == w then return gi, ji, g, gem end
		end
	end
	for gi, g in ipairs(groups) do
		for ji, gem in ipairs(g.gemList or { }) do
			if lower(gem.nameSpec):find(w, 1, true) then return gi, ji, g, gem end
		end
	end
	for gi, g in ipairs(groups) do
		if lower(g.label):find(w, 1, true) or lower(g.displayLabel):find(w, 1, true) then return gi, nil, g end
	end
	local n = tonumber(w:match("^group%s*(%d+)$") or "")
	if n and groups[n] then return n, nil, groups[n] end
end

local configOptions
local function resolveConfig(build, want)
	if not configOptions then
		local ok, list = pcall(LoadModule, "Modules/ConfigOptions")
		configOptions = ok and list or { }
	end
	local opt = best(configOptions, want, function(o) return o.var and strip(o.label) or "" end)
	if not opt then
		for _, o in ipairs(configOptions) do if o.var and lower(o.var) == lower(want) then opt = o end end
	end
	if not opt then return nil end
	return opt, build.configTab and build.configTab.varControls and build.configTab.varControls[opt.var]
end

local function resolveCalcs(build, want)
	local w = lower(want)
	for _, section in ipairs(build.calcsTab and build.calcsTab.sectionList or { }) do
		for _, sub in ipairs(section.subSection or { }) do
			for _, row in ipairs(sub.data or { }) do
				local label = lower(strip(row.label))
				if label ~= "" and (label == w or label:find(w, 1, true)) then return section, strip(row.label), strip(sub.label) end
			end
			if lower(strip(sub.label)) == w then return section, strip(sub.label), strip(sub.label) end
		end
	end
end

-- One mark from { target, kind?, text? }. kind: node | slot | flask | gem | config | calcs (auto when left out).
function Marks.Resolve(build, item)
	if type(item) ~= "table" then item = { target = item } end
	local want = item.target or item.name or item.id
	if want == nil or tostring(want) == "" then return nil, "a mark needs a target" end
	want = tostring(want)
	local kind = item.kind and lower(item.kind) or nil
	local mark = { text = item.text and tostring(item.text):gsub("[%c]+", " "):sub(1, 140) or nil, target = want }
	local function asNode()
		local node = resolveNode(build, want, kind)
		if not node then return nil end
		mark.kind, mark.view, mark.node = "node", "TREE", node.id
		mark.label = (node.dn or node.name) .. (node._markEffect and (": " .. node._markEffect) or "")
		node._markEffect = nil
		mark.allocated = node.alloc or nil
		if not node.alloc and node.path then
			mark.path = { }
			for _, p in ipairs(node.path) do t_insert(mark.path, p.id) end
			mark.points = #node.path
		end
		mark.where = node.alloc and "allocated" or (node.path and (#node.path .. " point" .. (#node.path == 1 and "" or "s") .. " from your tree") or "not reachable from your tree")
		return mark
	end
	local function asSlot()
		local slotName, slot = resolveSlot(build, want)
		if not slot then return nil end
		mark.kind = slotName:match("^Flask") and "flask" or "slot"
		mark.view, mark.slot = "ITEMS", slotName
		local item = slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId]
		mark.label = slotName .. (item and (": " .. (item.title or item.name or "")) or " (empty)")
		return mark
	end
	local function asGem()
		local gi, ji, group, gem = resolveGem(build, want)
		if not gi then return nil end
		mark.kind, mark.view, mark.group, mark.gem = "gem", "SKILLS", gi, ji
		mark.label = gem and (gem.nameSpec .. " (group " .. gi .. ")") or ("Group " .. gi .. ": " .. tostring(group.displayLabel or group.label or ""))
		return mark
	end
	local function asConfig()
		local opt = resolveConfig(build, want)
		if not opt then return nil end
		mark.kind, mark.view, mark.var = "config", "CONFIG", opt.var
		mark.label = strip(opt.label) .. (opt.section and "" or "")
		return mark
	end
	local function asCalcs()
		local section, label, sub = resolveCalcs(build, want)
		if not section then return nil end
		mark.kind, mark.view, mark.calcRow = "calcs", "CALCS", label
		mark.label = label .. (sub ~= label and (" (" .. sub .. ")") or "")
		return mark
	end
	local order = { node = { asNode }, slot = { asSlot }, flask = { asSlot }, gem = { asGem }, skill = { asGem }, config = { asConfig }, calcs = { asCalcs } }
	local tries = kind and order[kind] or { asSlot, asGem, asNode, asConfig, asCalcs }
	if not tries then return nil, "unknown kind " .. kind .. " (node, slot, flask, gem, config, calcs)" end
	for _, fn in ipairs(tries) do
		local m = fn()
		if m then return m end
	end
	return nil, 'nothing called "' .. want .. '"' .. (kind and (" (" .. kind .. ")") or "") .. " in this build"
end

-- Set the marks (an empty list clears them). Returns marks, errors.
function Marks.Set(build, items)
	local list, errors = { }, { }
	for _, item in ipairs(items or { }) do
		local m, err = Marks.Resolve(build, item)
		if m then m.n = #list + 1 t_insert(list, m) else t_insert(errors, err) end
	end
	build.agentMarks = #list > 0 and list or nil
	build.agentMarksAt = GetTime and GetTime() or 0
	return list, errors
end

function Marks.Clear(build) build.agentMarks = nil end

-- Drawing ------------------------------------------------------------------------------
local COL = { 1, 0.78, 0.2 } -- amber: stands out from PoB's own greens, reds and blues

local function pulse()
	local t = (GetTime and GetTime() or 0) / 1000
	return 0.55 + 0.45 * math.sin(t * 5)
end

local function outline(x, y, w, h, thick, a)
	SetDrawColor(COL[1], COL[2], COL[3], a)
	DrawImage(nil, x - thick, y - thick, w + thick * 2, thick)
	DrawImage(nil, x - thick, y + h, w + thick * 2, thick)
	DrawImage(nil, x - thick, y, thick, h)
	DrawImage(nil, x + w, y, thick, h)
end

-- The numbered box beside a mark. Returns its rectangle (a click on it dismisses the mark).
local function badge(m, x, y, maxRight)
	local text = "^x000000" .. m.n .. ". ^7" .. (m.text or m.label)
	local sub = m.text and m.label or nil
	local w = m_max(DrawStringWidth(16, "VAR", text), sub and DrawStringWidth(12, "VAR", sub) or 0) + 30
	if maxRight and x + w > maxRight then x = maxRight - w end
	local h = sub and 36 or 22
	SetDrawColor(COL[1], COL[2], COL[3])
	DrawImage(nil, x, y, w, h)
	SetDrawColor(0.05, 0.05, 0.07, 0.95)
	DrawImage(nil, x + 22, y + 1, w - 23, h - 2)
	DrawString(x + 6, y + 3, "LEFT", 16, "VAR BOLD", "^x000000" .. m.n)
	DrawString(x + 27, y + 3, "LEFT", 16, "VAR", "^7" .. (m.text or m.label))
	if sub then DrawString(x + 27, y + 20, "LEFT", 12, "VAR", "^8" .. sub) end
	return { x = x, y = y, w = w, h = h }
end

-- Where a mark's control is on screen (Items, Skills, Configuration, Calcs), or nil.
local function controlRect(build, m)
	local control
	if m.kind == "slot" or m.kind == "flask" then control = build.itemsTab.slots[m.slot]
	elseif m.kind == "gem" then
		local tab = build.skillsTab
		local group = tab.socketGroupList[m.group]
		if group and tab.displayGroup ~= group then tab:SetDisplayGroup(group) end
		control = m.gem and tab.gemSlots[m.gem] and tab.gemSlots[m.gem].nameSpec or tab.controls.groupList
	elseif m.kind == "config" then control = build.configTab.varControls[m.var]
	elseif m.kind == "calcs" then
		for _, section in ipairs(build.calcsTab.sectionList) do
			for _, sub in ipairs(section.subSection or { }) do
				for _, row in ipairs(sub.data or { }) do
					if strip(row.label) == m.calcRow then control = section end
				end
				if strip(sub.label) == m.calcRow then control = section end
			end
		end
	end
	if not control or not control.GetPos then return nil end
	local okShown, shown = pcall(control.IsShown, control)
	if okShown and not shown then return nil end
	local x, y = control:GetPos()
	local w, h = control:GetSize()
	return x, y, w, h
end

-- Draw the marks of the visible tab (not the tree: PassiveTreeView draws those) and the
-- "Clear AI marks" button. Clicks on a mark's box dismiss it.
function Marks.Draw(build, viewPort, inputEvents)
	local list = build.agentMarks
	if not list or #list == 0 then return end
	SetDrawLayer(nil, 90)
	local a = pulse()
	local cx, cy = GetCursorPos()
	local hit = { }
	if build.viewMode ~= "TREE" then
		for _, m in ipairs(list) do
			if m.view == build.viewMode then
				local x, y, w, h = controlRect(build, m)
				if x then
					outline(x, y, w, h, 3, a)
					hit[m] = badge(m, x + w + 10, y + h / 2 - 11, viewPort.x + viewPort.width - 4)
				end
			end
		end
	end
	-- Clear button (top right of the tab) and a hint for marks on other tabs.
	local label = "Clear AI marks (" .. #list .. ")"
	local bw = DrawStringWidth(14, "VAR", label) + 16
	local bx, by = viewPort.x + viewPort.width - bw - 8, viewPort.y + 6
	SetDrawColor(COL[1], COL[2], COL[3])
	DrawImage(nil, bx, by, bw, 22)
	SetDrawColor(0.08, 0.08, 0.1)
	DrawImage(nil, bx + 1, by + 1, bw - 2, 20)
	DrawString(bx + 8, by + 4, "LEFT", 14, "VAR", "^7" .. label)
	local others = { }
	for _, m in ipairs(list) do if m.view ~= build.viewMode then t_insert(others, m.n .. " on " .. m.view:sub(1, 1) .. m.view:sub(2):lower()) end end
	if #others > 0 then DrawString(bx - 8, by + 4, "RIGHT", 14, "VAR", "^xFFC830AI marks: " .. table.concat(others, ", ")) end
	for id, event in ipairs(inputEvents or { }) do
		if event.type == "KeyUp" and event.key == "LEFTBUTTON" then
			if cx >= bx and cx < bx + bw and cy >= by and cy < by + 22 then
				Marks.Clear(build)
				inputEvents[id] = nil
				return
			end
			for m, r in pairs(hit) do
				if cx >= r.x and cx < r.x + r.w and cy >= r.y and cy < r.y + r.h then
					Marks.Dismiss(build, m)
					inputEvents[id] = nil
					return
				end
			end
		end
	end
end

function Marks.Dismiss(build, mark)
	local keep = { }
	for _, m in ipairs(build.agentMarks or { }) do if m ~= mark then t_insert(keep, m) end end
	build.agentMarks = #keep > 0 and keep or nil
end

-- Tree marks (called by PassiveTreeView with its coordinates): a pulsing ring on the node,
-- rings on its path from the allocated tree, and the numbered box.
function Marks.DrawTree(build, spec, treeToScreen, scale, viewPort, inputEvents)
	local list = build.agentMarks
	if not list then return end
	SetDrawLayer(nil, 35)
	local a = pulse()
	local cx, cy = GetCursorPos()
	local hit = { }
	for _, m in ipairs(list) do
		local node = m.kind == "node" and spec.nodes[m.node]
		if node and node.x then
			for _, pid in ipairs(m.path or { }) do
				local p = spec.nodes[pid]
				if p and p.x and p ~= node then
					local px, py = treeToScreen(p.x, p.y)
					local r = m_max(6, (p.size or 30) * scale * 0.55)
					outline(px - r, py - r, r * 2, r * 2, 2, a * 0.7)
				end
			end
			local sx, sy = treeToScreen(node.x, node.y)
			local r = m_max(12, (node.size or 50) * scale * 0.8)
			outline(sx - r, sy - r, r * 2, r * 2, 4, a)
			hit[m] = badge(m, sx + r + 10, sy - 11, viewPort.x + viewPort.width - 4)
		end
	end
	for id, event in ipairs(inputEvents or { }) do
		if event.type == "KeyUp" and event.key == "LEFTBUTTON" then
			for m, rect in pairs(hit) do
				if cx >= rect.x and cx < rect.x + rect.w and cy >= rect.y and cy < rect.y + rect.h then
					Marks.Dismiss(build, m)
					inputEvents[id] = nil
					return
				end
			end
		end
	end
end

-- One line per mark for the AI's reply (and the headless "where it is" answer).
function Marks.Describe(m)
	local where = ({ TREE = "passive tree", ITEMS = "Items tab", SKILLS = "Skills tab", CONFIG = "Configuration tab", CALCS = "Calcs tab" })[m.view] or m.view
	local extra = m.kind == "node" and (", " .. m.where) or ""
	return string.format("%d. %s (%s, %s%s)%s", m.n, m.label, m.kind, where, extra, m.text and (": " .. m.text) or "")
end

return Marks
