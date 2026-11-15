-- Agent Edition: "point at it" marks.
--
-- The AI points at things the player can't find (set_view { view, point: [...] }):
-- a passive node, notable, mastery (also by one of its effects) or jewel socket on the
-- tree; an item slot or flask on the Items tab; a skill group or gem on the Skills tab;
-- a Configuration option; a Calcs row. Each mark is numbered (1, 2, 3 for step-by-step
-- help), drawn as a pulsing outline with a labelled box, and stays until the player
-- clicks it away, presses "Clear AI marks", or the AI clears them (point: []).
-- Styles (ring, blinking outline, glow, arrow) and meanings (do = green, problem = red,
-- info = blue; Okabe-Ito colours, readable with colour-vision deficiencies), a spotlight
-- that dims the rest, guided tours (Next / Back), the route to a node numbered in order,
-- an item's mod line, a candidate item's stat changes, gem swaps and socket colours, a
-- gain tag from PoB, a short history to show again, and a reduced-motion option.
-- Sizes are PoB UI units, so they follow PoB's own UI scale.
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

-- Gem socket colours (PoB's grantedEffect.color: 1 red, 2 green, 3 blue).
local SOCKET = { [1] = "red", [2] = "green", [3] = "blue" }
local function gemColour(gem)
	local effect = gem and (gem.grantedEffect or (gem.gemData and gem.gemData.grantedEffect))
	return effect and SOCKET[effect.color] or "white"
end
local function gemByName(build, name)
	local w = lower(name)
	for id, g in pairs(build.data and build.data.gems or data.gems or { }) do
		if lower(g.name) == w then return g end
	end
end

-- The mod lines of an item, as the player sees them.
local function itemLines(item)
	local out = { }
	for _, key in ipairs({ "enchantModLines", "implicitModLines", "explicitModLines", "crucibleModLines" }) do
		for _, l in ipairs(item[key] or { }) do
			local text = strip(l.line or "")
			if text ~= "" then t_insert(out, text) end
		end
	end
	return out
end

local STYLES = { ring = true, outline = true, glow = true, arrow = true }
local TONES = { ["do"] = true, problem = true, info = true }

-- One mark from { target, kind?, text?, style?, tone?, line?, candidate?, to?, to_slot?, ops? }.
-- kind: node | slot | flask | gem | config | calcs (auto when left out).
function Marks.Resolve(build, item)
	if type(item) ~= "table" then item = { target = item } end
	local want = item.target or item.name or item.id
	if want == nil or tostring(want) == "" then return nil, "a mark needs a target" end
	want = tostring(want)
	local kind = item.kind and lower(item.kind) or nil
	local mark = { text = item.text and tostring(item.text):gsub("[%c]+", " "):sub(1, 140) or nil, target = want,
		style = STYLES[lower(item.style)] and lower(item.style) or nil, tone = TONES[lower(item.tone)] and lower(item.tone) or nil }
	local function asNode()
		local node = resolveNode(build, want, kind)
		if not node then return nil end
		mark.kind, mark.view, mark.node = "node", "TREE", node.id
		mark.label = (node.dn or node.name) .. (node._markEffect and (": " .. node._markEffect) or "")
		node._markEffect = nil
		mark.allocated = node.alloc or nil
		if not node.alloc and node.path then
			-- The route from the allocated tree, numbered in the order to take it (nearest first).
			local path = { }
			for _, p in ipairs(node.path) do t_insert(path, p) end
			table.sort(path, function(a, b)
				local da, db = a.pathDist or 0, b.pathDist or 0
				if da ~= db then return da < db end
				return a.id < b.id
			end)
			mark.path = { }
			for _, p in ipairs(path) do t_insert(mark.path, p.id) end
			mark.points = #path
		end
		mark.where = node.alloc and "allocated" or (node.path and (#node.path .. " point" .. (#node.path == 1 and "" or "s") .. " from your tree") or "not reachable from your tree")
		return mark
	end
	local function asSlot()
		local slotName, slot = resolveSlot(build, want)
		if not slot then return nil end
		mark.kind = slotName:match("^Flask") and "flask" or "slot"
		mark.view, mark.slot = "ITEMS", slotName
		local it = slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId]
		mark.label = slotName .. (it and (": " .. (it.title or it.name or "")) or " (empty)")
		if it then mark.itemName = it.title or it.name end
		-- One mod line of the item to point at.
		if item.line and it then
			local w = lower(item.line)
			for i, l in ipairs(itemLines(it)) do
				if lower(l):find(w, 1, true) then mark.line, mark.lineIndex = l, i break end
			end
			if not mark.line then return nil, 'no line "' .. tostring(item.line) .. '" on ' .. tostring(mark.itemName) end
			mark.lines = itemLines(it)
		end
		return mark
	end
	local function asGem()
		local gi, ji, group, gem = resolveGem(build, want)
		if not gi then return nil end
		mark.kind, mark.view, mark.group, mark.gem = "gem", "SKILLS", gi, ji
		mark.label = gem and (gem.nameSpec .. " (group " .. gi .. ")") or ("Group " .. gi .. ": " .. tostring(group.displayLabel or group.label or ""))
		if gem then mark.socket = gemColour(gem) end
		if item.to then
			local g = gemByName(build, item.to)
			mark.to = g and g.name or tostring(item.to)
			mark.toSocket = g and SOCKET[g.grantedEffect and g.grantedEffect.color] or (g and "white") or nil
		end
		if item.to_slot then mark.toSlot = tostring(item.to_slot) mark.fromSlot = group.slot end
		return mark
	end
	local function asConfig()
		local opt = resolveConfig(build, want)
		if not opt then return nil end
		mark.kind, mark.view, mark.var = "config", "CONFIG", opt.var
		mark.label = strip(opt.label)
		return mark
	end
	local function asCalcs()
		local section, label, sub = resolveCalcs(build, want)
		if not section then return nil end
		mark.kind, mark.view, mark.calcRow = "calcs", "CALCS", label
		mark.label = label .. (sub ~= label and (" (" .. sub .. ")") or "")
		return mark
	end
	local order = { node = { asNode }, slot = { asSlot }, item = { asSlot }, flask = { asSlot }, gem = { asGem }, skill = { asGem }, config = { asConfig }, calcs = { asCalcs } }
	local tries = kind and order[kind] or { asSlot, asGem, asNode, asConfig, asCalcs }
	if not tries then return nil, "unknown kind " .. kind .. " (node, slot, flask, gem, config, calcs)" end
	for _, fn in ipairs(tries) do
		local m, err = fn()
		if m then return m end
		if err then return nil, err end
	end
	return nil, 'nothing called "' .. want .. '"' .. (kind and (" (" .. kind .. ")") or "") .. " in this build"
end

-- Set the marks (an empty list clears them). opts = { tour = bool, title }. Returns marks, errors.
-- Every set is kept in a short history ("show me again").
Marks.HISTORY = 10
function Marks.Set(build, items, opts)
	opts = opts or { }
	local list, errors = { }, { }
	for _, item in ipairs(items or { }) do
		local m, err = Marks.Resolve(build, item)
		if m then m.n = #list + 1 m.source = item t_insert(list, m) else t_insert(errors, err) end
	end
	build.agentMarks = #list > 0 and list or nil
	build.agentTour = (#list > 0 and opts.tour) and { step = 1 } or nil
	build.agentMarksAt = GetTime and GetTime() or 0
	if #list > 0 and not opts.replay then
		build.agentMarksHistory = build.agentMarksHistory or { }
		local h = build.agentMarksHistory
		local raw = { }
		for _, m in ipairs(list) do t_insert(raw, m.source) end
		t_insert(h, { title = opts.title or list[1].label, count = #list, tour = opts.tour or nil, items = raw, at = os.time() })
		while #h > Marks.HISTORY do table.remove(h, 1) end
	end
	return list, errors
end

-- Replay a set from the history: 1 = the latest, 2 = the one before...
function Marks.Again(build, back)
	local h = build.agentMarksHistory or { }
	local entry = h[#h - ((tonumber(back) or 1) - 1)]
	if not entry then return nil, "no earlier marks to show again" end
	return Marks.Set(build, entry.items, { tour = entry.tour, title = entry.title, replay = true })
end

function Marks.Clear(build)
	if build.agentMarks then build.agentMarksClearedAt = GetTime and GetTime() or 0 end
	build.agentMarks, build.agentTour = nil, nil
end

-- Tours: one step at a time with Next / Back.
function Marks.Step(build, delta)
	local tour, list = build.agentTour, build.agentMarks
	if not tour or not list then return nil end
	tour.step = m_max(1, m_min(#list, tour.step + delta))
	local m = list[tour.step]
	build.viewMode = m.view
	if m.kind == "node" and build.treeTab and build.treeTab.FocusNode then build.treeTab:FocusNode(m.node) end
	return tour.step
end

-- Which marks are drawn now: all of them, or the current tour step.
function Marks.Visible(build)
	local list = build.agentMarks or { }
	if build.agentTour then return { list[build.agentTour.step] } end
	return list
end

-- Settings: reduced motion (no pulsing, blinking or zoom animation), kept in AgentEdition.json.
-- Cached on main (shared by every copy of this module: the chat panel loads its own).
function Marks.ReducedMotion()
	local holder = main or Marks
	if holder.agentReducedMotion ~= nil then return holder.agentReducedMotion end
	local ok, Settings = pcall(LoadModule, "Agent/Settings")
	holder.agentReducedMotion = ok and main and main.userPath and Settings.get(main.userPath, "marksReducedMotion") == true or false
	return holder.agentReducedMotion
end
function Marks.SetReducedMotion(on)
	local holder = main or Marks
	holder.agentReducedMotion = on and true or false
	local ok, Settings = pcall(LoadModule, "Agent/Settings")
	if ok and main and main.userPath then Settings.set(main.userPath, "marksReducedMotion", holder.agentReducedMotion or "") end
	return holder.agentReducedMotion
end

-- Drawing ------------------------------------------------------------------------------
-- Okabe-Ito colours (readable with the common colour-vision deficiencies): bluish green = do
-- this, vermillion = a problem, sky blue = information, orange = no meaning given. Styles
-- differ in shape too, so meaning never rests on colour alone.
Marks.TONES = {
	["do"] = { 0, 0.62, 0.45, "^x009E73" },
	problem = { 0.84, 0.37, 0, "^xD55E00" },
	info = { 0.34, 0.71, 0.91, "^x56B4E9" },
	none = { 0.9, 0.62, 0, "^xE69F00" },
}
local function toneOf(m) return Marks.TONES[m.tone or "none"] or Marks.TONES.none end

-- 0..1 brightness for pulsing / blinking; constant with reduced motion.
function Marks.Pulse(style)
	if Marks.ReducedMotion() then return 1 end
	local t = (GetTime and GetTime() or 0) / 1000
	if style == "outline" then return (math.floor(t * 2.5) % 2 == 0) and 1 or 0.25 end -- blinking
	if style == "glow" then return 0.75 + 0.25 * math.sin(t * 3) end
	return 0.55 + 0.45 * math.sin(t * 5)
end

local function frame(c, x, y, w, h, thick, a)
	SetDrawColor(c[1], c[2], c[3], a)
	DrawImage(nil, x - thick, y - thick, w + thick * 2, thick)
	DrawImage(nil, x - thick, y + h, w + thick * 2, thick)
	DrawImage(nil, x - thick, y, thick, h)
	DrawImage(nil, x + w, y, thick, h)
end

-- The mark itself around a rectangle, in its style.
local function drawStyle(m, x, y, w, h)
	local c = toneOf(m)
	local style = m.style or (m.kind == "node" and "ring" or "outline")
	local a = Marks.Pulse(style)
	if style == "glow" then
		for i = 4, 1, -1 do frame(c, x - i * 3, y - i * 3, w + i * 6, h + i * 6, 3, a * 0.12 * (5 - i)) end
		frame(c, x, y, w, h, 2, a)
	elseif style == "arrow" then
		frame(c, x, y, w, h, 2, 0.8)
		-- an arrow from the left pointing at the target
		local ax, ay = x - 46, y + h / 2
		SetDrawColor(c[1], c[2], c[3], a)
		DrawImage(nil, ax, ay - 3, 30, 6)
		for i = 0, 10 do DrawImage(nil, ax + 30 + i, ay - 10 + i, 1, 20 - i * 2) end
	else
		frame(c, x, y, w, h, style == "ring" and 4 or 3, a)
	end
end

-- Dim everything in the view port except one rectangle (the spotlight).
local function spotlight(viewPort, x, y, w, h)
	local pad = 12
	x, y, w, h = x - pad, y - pad, w + pad * 2, h + pad * 2
	SetDrawColor(0, 0, 0, 0.55)
	local vx, vy, vw, vh = viewPort.x, viewPort.y, viewPort.width, viewPort.height
	DrawImage(nil, vx, vy, vw, m_max(0, y - vy))
	DrawImage(nil, vx, y + h, vw, m_max(0, vy + vh - y - h))
	DrawImage(nil, vx, y, m_max(0, x - vx), h)
	DrawImage(nil, x + w, y, m_max(0, vx + vw - x - w), h)
end

-- The gain tag ("+2.7% DPS / +15% EHP"), from PoB (the mark's ops simulated with what_if).
function Marks.GainTag(g)
	if not g then return nil end
	local parts = { }
	local function p(v, what) if v and math.abs(v) >= 0.05 then t_insert(parts, string.format("%s%.1f%% %s", v > 0 and "+" or "", v, what)) end end
	p(g.dpsPct, "DPS") p(g.ehpPct, "EHP") p(g.hitPct, "max hit")
	return #parts > 0 and table.concat(parts, " / ") or "no change in PoB"
end

-- The lines of a mark's box (also used by the tests).
function Marks.BoxLines(build, m)
	local c = toneOf(m)
	local L = { { size = 16, text = "^7" .. (m.text or m.label) } }
	if m.text then t_insert(L, { size = 12, text = "^8" .. m.label }) end
	if m.gain then t_insert(L, { size = 14, text = (m.gain.good and "^x009E73" or "^xD55E00") .. m.gain.tag }) end
	if m.lines then
		for i, l in ipairs(m.lines) do
			if i == m.lineIndex then t_insert(L, { size = 14, text = c[4] .. "> " .. l })
			elseif math.abs(i - m.lineIndex) <= 2 then t_insert(L, { size = 12, text = "^8  " .. l }) end
		end
	end
	if m.candidate then
		t_insert(L, { size = 12, text = "^7Replaces: " .. tostring(m.candidate.replaces or "nothing") })
		for _, d in ipairs(m.candidate.deltas or { }) do t_insert(L, { size = 12, text = (d.good and "^x009E73" or "^xD55E00") .. d.text }) end
	end
	if m.to then t_insert(L, { size = 14, text = "^7swap ^x" .. (m.socket == "red" and "FF6060" or m.socket == "green" and "60D060" or m.socket == "blue" and "7090FF" or "DDDDDD") .. (build and m.label:match("^(.-) %(") or m.target) .. " ^7-> " .. ((m.toSocket == "red" and "^xFF6060") or (m.toSocket == "green" and "^x60D060") or (m.toSocket == "blue" and "^x7090FF") or "^xDDDDDD") .. m.to .. " ^8(" .. tostring(m.toSocket or "?") .. " socket)" }) end
	if m.socket and not m.to then t_insert(L, { size = 12, text = "^8" .. m.socket .. " socket" }) end
	if m.toSlot then t_insert(L, { size = 12, text = "^7move to: " .. m.toSlot .. (m.fromSlot and (" ^8(now: " .. m.fromSlot .. ")") or "") }) end
	return L
end

-- The numbered box beside a mark (with Next / Back on a tour). Returns its rectangles.
local function badge(build, m, x, y, maxRight)
	local c = toneOf(m)
	local L = Marks.BoxLines(build, m)
	local w, h = 0, 6
	for _, l in ipairs(L) do w = m_max(w, DrawStringWidth(l.size, "VAR", l.text)) h = h + l.size + 2 end
	local tour = build.agentTour
	if tour then h = h + 24 end
	w = m_max(w, tour and 170 or 0) + 34
	if maxRight and x + w > maxRight then x = maxRight - w end
	SetDrawColor(c[1], c[2], c[3])
	DrawImage(nil, x, y, w, h)
	SetDrawColor(0.05, 0.05, 0.07, 0.95)
	DrawImage(nil, x + 24, y + 1, w - 25, h - 2)
	DrawString(x + 5, y + 3, "LEFT", 16, "VAR BOLD", "^x000000" .. m.n)
	local ly = y + 3
	for _, l in ipairs(L) do DrawString(x + 29, ly, "LEFT", l.size, "VAR", l.text) ly = ly + l.size + 2 end
	local out = { box = { x = x, y = y, w = w, h = h } }
	if tour then
		local by = y + h - 22
		out.back = { x = x + 29, y = by, w = 60, h = 18 }
		out.next = { x = x + 95, y = by, w = 60, h = 18 }
		for _, b in ipairs({ { out.back, "< Back", tour.step > 1 }, { out.next, tour.step < #build.agentMarks and "Next >" or "Done", true } }) do
			local r = b[1]
			SetDrawColor(c[1], c[2], c[3], b[3] and 1 or 0.3)
			DrawImage(nil, r.x, r.y, r.w, r.h)
			SetDrawColor(0.1, 0.1, 0.12)
			DrawImage(nil, r.x + 1, r.y + 1, r.w - 2, r.h - 2)
			DrawString(r.x + r.w / 2, r.y + 2, "CENTER_X", 14, "VAR", (b[3] and "^7" or "^8") .. b[2])
		end
		DrawString(x + 165, by + 2, "LEFT", 12, "VAR", "^8" .. tour.step .. " of " .. #build.agentMarks)
	end
	return out
end

-- Input --------------------------------------------------------------------------------
-- The tabs handle the mouse before anything drawn over them (the Items list, dropdowns,
-- the tree), so the marks cannot wait for their own draw call to see a click. Every
-- clickable area drawn this frame is recorded here; Marks.HandleInput runs BEFORE the tab
-- on the next frame (Modules/Build.lua), acts on clicks inside those areas and takes them
-- (press and release), so the controls underneath never see them. Esc closes the marks.
local function addHit(build, rect, action, name)
	build.agentMarksHitsNext = build.agentMarksHitsNext or { }
	t_insert(build.agentMarksHitsNext, { r = rect, action = action, name = name })
end

-- A mark's box: Next / Back on a tour (checked first), else a click dismisses it.
local function addBoxHits(build, m, r)
	if r.next then
		addHit(build, r.next, function()
			if build.agentTour and build.agentTour.step >= #(build.agentMarks or { }) then Marks.Clear(build) else Marks.Step(build, 1) end
		end, "next")
	end
	if r.back then addHit(build, r.back, function() Marks.Step(build, -1) end, "back") end
	addHit(build, r.box, function()
		if build.agentTour then Marks.Clear(build) else Marks.Dismiss(build, m) end
	end, "box")
end

-- The clickable area at a point (last frame's), or nil.
function Marks.HitAt(build, x, y)
	for _, h in ipairs(build.agentMarksHits or { }) do
		local r = h.r
		if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h then return h end
	end
end

-- Called by Build before the tab draws: clicks on marks, boxes and buttons, and Esc.
function Marks.HandleInput(build, inputEvents)
	local cx, cy = GetCursorPos()
	for id, event in ipairs(inputEvents or { }) do
		if event.type == "KeyDown" and event.key == "ESCAPE" and build.agentMarks then
			Marks.Clear(build)
			inputEvents[id] = nil
		elseif event.key == "LEFTBUTTON" or event.key == "RIGHTBUTTON" or event.key == "WHEELUP" or event.key == "WHEELDOWN" then
			local h = Marks.HitAt(build, cx, cy)
			if h then
				if event.type == "KeyUp" and event.key == "LEFTBUTTON" then h.action() end
				inputEvents[id] = nil
			end
		end
	end
end

-- Called by Build after the marks were drawn: this frame's areas become the next frame's.
function Marks.EndFrame(build)
	build.agentMarksHits = build.agentMarksHitsNext
	build.agentMarksHitsNext = nil
end

-- Where a mark's control is on screen (Items, Skills, Configuration, Calcs), or nil.
local function controlRect(build, m, which)
	local control
	if m.kind == "slot" or m.kind == "flask" then control = build.itemsTab.slots[m.slot]
	elseif m.kind == "gem" then
		local tab = build.skillsTab
		local group = tab.socketGroupList[m.group]
		if group and tab.displayGroup ~= group then tab:SetDisplayGroup(group) end
		if which == "toSlot" then control = tab.controls.groupSlot
		else control = m.gem and tab.gemSlots[m.gem] and tab.gemSlots[m.gem].nameSpec or tab.controls.groupList end
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

local function buttonRow(build, viewPort)
	local list = build.agentMarks
	local labels = { "Clear AI marks (" .. #list .. ")", Marks.ReducedMotion() and "Motion: off" or "Motion: on" }
	local x, out = viewPort.x + viewPort.width - 8, { }
	for i = #labels, 1, -1 do
		local w = DrawStringWidth(14, "VAR", labels[i]) + 16
		x = x - w
		out[i] = { x = x, y = viewPort.y + 6, w = w, h = 22, label = labels[i] }
		x = x - 6
	end
	for _, b in ipairs(out) do
		local c = Marks.TONES.none
		SetDrawColor(c[1], c[2], c[3])
		DrawImage(nil, b.x, b.y, b.w, b.h)
		SetDrawColor(0.08, 0.08, 0.1)
		DrawImage(nil, b.x + 1, b.y + 1, b.w - 2, b.h - 2)
		DrawString(b.x + 8, b.y + 4, "LEFT", 14, "VAR", "^7" .. b.label)
	end
	return out
end

-- Draw the marks of the visible tab (the tree's are drawn by PassiveTreeView) and the
-- Clear / Motion buttons. Clicks on a box: Next / Back on a tour, else dismiss.
function Marks.Draw(build, viewPort, inputEvents)
	local list = build.agentMarks
	if not list or #list == 0 then return end
	SetDrawLayer(3, 0)
	local visible = Marks.Visible(build)
	if build.viewMode ~= "TREE" then
		for _, m in ipairs(visible) do
			if m.view == build.viewMode then
				local x, y, w, h = controlRect(build, m)
				if x then
					if build.agentTour or #list == 1 then spotlight(viewPort, x, y, w, h) end
					drawStyle(m, x, y, w, h)
					if m.toSlot then
						local tx, ty, tw, th = controlRect(build, m, "toSlot")
						if tx then drawStyle({ tone = "do", style = "arrow", kind = "gem" }, tx, ty, tw, th) end
					end
					addBoxHits(build, m, badge(build, m, x + w + 12, y + h / 2 - 11, viewPort.x + viewPort.width - 4))
				end
			end
		end
	end
	-- The buttons first: they win over a box drawn under them.
	local buttons = buttonRow(build, viewPort)
	local hits = build.agentMarksHitsNext or { }
	build.agentMarksHitsNext = { }
	addHit(build, buttons[1], function() Marks.Clear(build) end, "clear")
	addHit(build, buttons[2], function() Marks.SetReducedMotion(not Marks.ReducedMotion()) end, "motion")
	for _, h in ipairs(hits) do t_insert(build.agentMarksHitsNext, h) end
	local others = { }
	for _, m in ipairs(visible) do if m.view ~= build.viewMode then t_insert(others, m.n .. " on " .. m.view:sub(1, 1) .. m.view:sub(2):lower()) end end
	if #others > 0 then DrawString(buttons[1].x - 8, buttons[1].y + 4, "RIGHT", 14, "VAR", "^xE69F00AI marks: " .. table.concat(others, ", ") .. "  ^8(Esc closes)") end
end

-- "Show AI marks again": a small button for a minute after the marks were cleared.
Marks.AGAIN_MS = 60000
function Marks.DrawAgain(build, viewPort, inputEvents)
	local h = build.agentMarksHistory
	local at = build.agentMarksClearedAt
	if not h or #h == 0 or not at or (GetTime() - at) > Marks.AGAIN_MS then return end
	local label = "Show AI marks again"
	local w = DrawStringWidth(14, "VAR", label) + 16
	local r = { x = viewPort.x + viewPort.width - w - 8, y = viewPort.y + 6, w = w, h = 22 }
	SetDrawLayer(3, 0)
	local c = Marks.TONES.none
	SetDrawColor(c[1], c[2], c[3], 0.7)
	DrawImage(nil, r.x, r.y, r.w, r.h)
	SetDrawColor(0.08, 0.08, 0.1)
	DrawImage(nil, r.x + 1, r.y + 1, r.w - 2, r.h - 2)
	DrawString(r.x + 8, r.y + 4, "LEFT", 14, "VAR", "^7" .. label)
	addHit(build, r, function() Marks.Again(build, 1) end, "again")
end

function Marks.Dismiss(build, mark)
	local keep = { }
	for _, m in ipairs(build.agentMarks or { }) do if m ~= mark then t_insert(keep, m) end end
	for i, m in ipairs(keep) do m.n = i end
	if #keep == 0 then Marks.Clear(build) else build.agentMarks = keep end
end

-- Tree marks (called by PassiveTreeView with its coordinates): the mark on the node, its
-- route from the allocated tree lit and numbered in the order to take it, the box, and a
-- spotlight on a single mark or a tour step.
function Marks.DrawTree(build, spec, treeToScreen, scale, viewPort, inputEvents)
	local list = build.agentMarks
	if not list then return end
	SetDrawLayer(nil, 35)
	local visible = Marks.Visible(build)
	for _, m in ipairs(visible) do
		local node = m.kind == "node" and spec.nodes[m.node]
		if node and node.x then
			local sx, sy = treeToScreen(node.x, node.y)
			local r = m_max(12, (node.size or 50) * scale * 0.8)
			if build.agentTour or #list == 1 then spotlight(viewPort, sx - r, sy - r, r * 2, r * 2) end
			local c = toneOf(m)
			for i, pid in ipairs(m.path or { }) do
				local p = spec.nodes[pid]
				if p and p.x and p ~= node then
					local px, py = treeToScreen(p.x, p.y)
					local pr = m_max(7, (p.size or 30) * scale * 0.55)
					frame(c, px - pr, py - pr, pr * 2, pr * 2, 2, 0.85)
					DrawString(px, py - pr - 16, "CENTER_X", 14, "VAR BOLD", c[4] .. i)
				end
			end
			drawStyle(m, sx - r, sy - r, r * 2, r * 2)
			addBoxHits(build, m, badge(build, m, sx + r + 10, sy - 11, viewPort.x + viewPort.width - 4))
		end
	end
end

-- One line per mark for the AI's reply (and the headless "where it is" answer).
function Marks.Describe(m)
	local where = ({ TREE = "passive tree", ITEMS = "Items tab", SKILLS = "Skills tab", CONFIG = "Configuration tab", CALCS = "Calcs tab" })[m.view] or m.view
	local extra = m.kind == "node" and (", " .. m.where) or ""
	local bits = { }
	if m.line then t_insert(bits, 'line "' .. m.line .. '"') end
	if m.to then t_insert(bits, "swap for " .. m.to .. " (" .. tostring(m.toSocket) .. " socket; now " .. tostring(m.socket) .. ")") end
	if m.toSlot then t_insert(bits, "move to " .. m.toSlot) end
	if m.gain then t_insert(bits, m.gain.tag) end
	if m.candidate then t_insert(bits, "replaces " .. tostring(m.candidate.replaces)) end
	return string.format("%d. %s (%s, %s%s)%s%s", m.n, m.label, m.kind, where, extra, m.text and (": " .. m.text) or "", #bits > 0 and (" [" .. table.concat(bits, "; ") .. "]") or "")
end

return Marks
