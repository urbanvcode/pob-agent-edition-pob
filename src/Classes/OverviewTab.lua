-- Path of Building — Agent Edition
--
-- Class: Overview Tab
-- A dashboard of the current build: headline numbers, defences, damage
-- breakdown and a build-health checklist, drawn as infographics.
--
local Viz = LoadModule("Agent/Viz")
local col = Viz.col
local m_max, m_min, m_floor, m_pi = math.max, math.min, math.floor, math.pi
local t_insert = table.insert

local OverviewTabClass = newClass("OverviewTab", "ControlHost", "Control", function(self, build)
	self.ControlHost()
	self.Control()
	self.build = build
	self.scrollY = 0
	self.contentHeight = 0
end)

local ELEMENTS = {
	{ key = "Fire", label = "Fire", col = col.fire },
	{ key = "Cold", label = "Cold", col = col.cold },
	{ key = "Lightning", label = "Lightning", col = col.lightning },
	{ key = "Chaos", label = "Chaos", col = col.chaos },
}

local function out(o, k) return tonumber(o[k]) or 0 end

function OverviewTabClass:MainSkillName()
	local ok, name = pcall(function()
		local skill = self.build.calcsTab.mainEnv.player.mainSkill
		return skill.activeEffect.grantedEffect.name
	end)
	return ok and name or nil
end

-- Build-health checklist: { { level = "good"|"warn"|"bad", text = ... }, ... }
function OverviewTabClass:HealthChecks(o)
	local checks = { }
	local function add(level, text) t_insert(checks, { level = level, text = text }) end

	local uncapped = { }
	for _, e in ipairs(ELEMENTS) do
		if e.key ~= "Chaos" then
			local v = out(o, e.key .. "Resist")
			if v < 75 then t_insert(uncapped, string.format("%s %d%%", e.label, v)) end
		end
	end
	if #uncapped > 0 then
		add("bad", "Uncapped resistances: " .. table.concat(uncapped, ", "))
	else
		add("good", "Elemental resistances capped")
	end
	local chaos = out(o, "ChaosResist")
	if chaos < 0 then add("bad", string.format("Negative chaos resistance (%d%%)", chaos))
	elseif chaos < 30 then add("warn", string.format("Low chaos resistance (%d%%)", chaos))
	else add("good", string.format("Chaos resistance %d%%", chaos)) end

	-- Weakest max hit compared with the others
	local hits, sum, n = { }, 0, 0
	for _, t in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
		local v = out(o, t .. "MaximumHitTaken")
		if v > 0 then hits[t] = v; sum = sum + v; n = n + 1 end
	end
	if n > 1 then
		local weakest, wv
		for t, v in pairs(hits) do if not wv or v < wv then weakest, wv = t, v end end
		if wv < (sum / n) * 0.55 then
			add("warn", string.format("Weak to %s hits (max %s vs avg %s)", weakest:lower(), Viz.num(wv), Viz.num(sum / n)))
		end
	end

	if out(o, "ManaUnreserved") < 0 then
		add("bad", string.format("Mana over-reserved by %s", Viz.num(-out(o, "ManaUnreserved"))))
	end
	local supp = out(o, "EffectiveSpellSuppressionChance")
	if supp >= 100 then add("good", "Spell suppression capped")
	elseif supp >= 50 then add("warn", string.format("Spell suppression %d%% (not capped)", supp)) end

	if out(o, "LifeLeechGainRate") <= 0 and out(o, "LifeRegenRecovery") <= 0 and out(o, "EnergyShieldRegenRecovery") <= 0 and out(o, "Life") > 1 then
		add("warn", "No life leech or regeneration")
	end

	local reqs = { { "Str", "Strength" }, { "Dex", "Dexterity" }, { "Int", "Intelligence" } }
	for _, r in ipairs(reqs) do
		local have, need = out(o, r[1]), out(o, "Req" .. r[1])
		if need > have then add("bad", string.format("%s requirement not met (%d / %d)", r[2], have, need)) end
	end

	for _, line in pairs(self.build.controls.warnings and self.build.controls.warnings.lines or { }) do
		add("warn", tostring(line):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", ""))
	end
	return checks
end

-- Cards ------------------------------------------------------------------------
function OverviewTabClass:DrawHeader(x, y, w, o)
	local spec = self.build.spec
	Viz.text(x, y, "LEFT", 26, "VAR BOLD", Viz.fit(26, "VAR BOLD", self.build.buildName or "Unnamed build", w), col.text)
	local class = spec.curAscendClassName ~= "None" and spec.curAscendClassName or spec.curClassName
	local parts = { string.format("Level %d %s", self.build.characterLevel or 1, spec.curClassName or "?") }
	if spec.curAscendClassName and spec.curAscendClassName ~= "None" then t_insert(parts, spec.curAscendClassName) end
	if spec.curSecondaryAscendClassName and spec.curSecondaryAscendClassName ~= "None" then t_insert(parts, spec.curSecondaryAscendClassName) end
	local skill = self:MainSkillName()
	if skill then t_insert(parts, "Main skill: " .. skill) end
	Viz.text(x, y + 32, "LEFT", 16, "VAR", Viz.fit(16, "VAR", table.concat(parts, "   |   "), w), col.muted)
	return 56
end

function OverviewTabClass:DrawTiles(x, y, w, o)
	local hits = { }
	for _, t in ipairs({ "Physical", "Fire", "Cold", "Lightning", "Chaos" }) do
		local v = out(o, t .. "MaximumHitTaken")
		if v > 0 then t_insert(hits, { t = t, v = v }) end
	end
	table.sort(hits, function(a, b) return a.v < b.v end)
	local weakest = hits[1]
	local pool = out(o, "Life") + out(o, "EnergyShield")

	local tiles = {
		{ label = "Combined DPS", value = Viz.num(out(o, "CombinedDPS")), sub = "Hit " .. Viz.num(out(o, "TotalDPS")) .. "  |  DoT " .. Viz.num(out(o, "TotalDotDPS")), c = col.accent },
		{ label = "Effective Hit Pool", value = Viz.num(out(o, "TotalEHP")), sub = string.format("Armour %s  |  Evasion %s", Viz.num(out(o, "Armour")), Viz.num(out(o, "Evasion"))), c = col.good },
		{ label = "Life + Energy Shield", value = Viz.num(pool), sub = string.format("Life %s  |  ES %s", Viz.num(out(o, "Life")), Viz.num(out(o, "EnergyShield"))), c = col.life },
		{ label = "Weakest Max Hit", value = weakest and Viz.num(weakest.v) or "-", sub = weakest and (weakest.t .. " damage") or "", c = weakest and col[weakest.t:lower()] or col.muted },
	}
	local gap = 12
	local perRow = w >= 820 and #tiles or 2
	local rows = math.ceil(#tiles / perRow)
	local tw = (w - gap * (perRow - 1)) / perRow
	local th = 84
	for i, t in ipairs(tiles) do
		local tx = x + ((i - 1) % perRow) * (tw + gap)
		local ty = y + m_floor((i - 1) / perRow) * (th + gap)
		local inner = tw - 28
		Viz.softRect(tx, ty, tw, th, col.card)
		Viz.outline(tx, ty, tw, th, col.border)
		Viz.rect(tx, ty + 8, 3, th - 16, t.c)
		Viz.text(tx + 16, ty + 10, "LEFT", 14, "VAR", Viz.fit(14, "VAR", t.label:upper(), inner), col.muted)
		Viz.text(tx + 16, ty + 28, "LEFT", 30, "VAR BOLD", t.value, col.text)
		Viz.text(tx + 16, ty + 62, "LEFT", 13, "VAR", Viz.fit(13, "VAR", t.sub, inner), col.muted)
	end
	return rows * th + (rows - 1) * gap
end

function OverviewTabClass:CardResists(x, y, w, h, o)
	local cx, cy, cw = Viz.card(x, y, w, h, "Resistances", "bar = 0-90%, line = 75% cap")
	local rowH = (h - 52) / 4
	for i, e in ipairs(ELEMENTS) do
		local ry = cy + (i - 1) * rowH
		local v = out(o, e.key .. "Resist")
		local over = out(o, e.key .. "ResistOverCap")
		local scale = 90
		Viz.text(cx, ry + 2, "LEFT", 15, "VAR", e.label, e.col)
		local label = Viz.pct(v)
		if over > 0 then label = label .. Viz.hex(col.muted) .. string.format("  (+%d over)", over) end
		local valueCol = (e.key == "Chaos" and (v < 0 and col.bad or col.text)) or (v < 75 and col.bad or col.text)
		Viz.text(cx + cw, ry + 2, "RIGHT", 15, "VAR BOLD", label, valueCol)
		local by = ry + 21
		Viz.bar(cx, by, cw, 8, m_max(0, v) / scale, e.col)
		if v < 0 then
			Viz.rect(cx, by, 3, 8, col.bad)
		end
		local capX = cx + cw * 75 / scale
		Viz.rect(capX - 1, by - 3, 2, 14, col.text, 0.65)
	end
end

function OverviewTabClass:CardMaxHit(x, y, w, h, o)
	local types = { "Physical", "Fire", "Cold", "Lightning", "Chaos" }
	local maxV, minV, minT = 1, nil, nil
	for _, t in ipairs(types) do
		local v = out(o, t .. "MaximumHitTaken")
		maxV = m_max(maxV, v)
		if v > 0 and (not minV or v < minV) then minV, minT = v, t end
	end
	local cx, cy, cw = Viz.card(x, y, w, h, "Max Hit Taken", "biggest hit you survive")
	local rowH = (h - 52) / #types
	local labelW = 70
	for i, t in ipairs(types) do
		local ry = cy + (i - 1) * rowH
		local v = out(o, t .. "MaximumHitTaken")
		local c = col[t:lower()]
		Viz.text(cx, ry + 1, "LEFT", 14, "VAR", t, c)
		local bw = cw - labelW - 54
		Viz.bar(cx + labelW, ry + 4, bw, 9, v / maxV, t == minT and col.bad or c)
		Viz.text(cx + cw, ry + 1, "RIGHT", 14, "VAR BOLD", Viz.num(v), t == minT and col.bad or col.text)
	end
end

function OverviewTabClass:CardAvoidance(x, y, w, h, o)
	local cx, cy, cw, ch = Viz.card(x, y, w, h, "Avoidance & Mitigation")
	local gauges = {
		{ label = "Evade", v = out(o, "EvadeChance"), c = col.dex },
		{ label = "Suppress", v = out(o, "EffectiveSpellSuppressionChance"), c = col.int },
		{ label = "Block", v = out(o, "BlockChance"), c = col.str, max = 75 },
		{ label = "Spell Block", v = out(o, "SpellBlockChance"), c = col.cold, max = 75 },
		{ label = "Phys Reduct.", v = out(o, "PhysicalDamageReduction"), c = col.physical, max = 90 },
	}
	local n = #gauges
	local slot = cw / n
	local r = m_min(slot / 2 - 6, (ch - 28) / 2)
	r = m_max(r, 16)
	for i, g in ipairs(gauges) do
		local gx = cx + slot * (i - 0.5)
		local gy = cy + r + 2
		Viz.ring(gx, gy, r, m_max(5, r * 0.22), g.v / (g.max or 100), g.v > 0 and g.c or col.track)
		Viz.text(gx, gy - 9, "CENTER", 16, "VAR BOLD", Viz.pct(g.v), g.v > 0 and col.text or col.muted)
		Viz.text(gx, gy + r + 6, "CENTER", 13, "VAR", g.label, col.muted)
	end
end

function OverviewTabClass:CardDamage(x, y, w, h, o)
	local cx, cy, cw, ch = Viz.card(x, y, w, h, "Damage Breakdown", Viz.num(out(o, "CombinedDPS")) .. " combined")
	local ign, bleed, poison = out(o, "IgniteDPS"), out(o, "BleedDPS"), out(o, "PoisonDPS")
	local otherDot = m_max(0, out(o, "TotalDotDPS") - ign - bleed - poison)
	local segs = {
		{ label = "Hits", value = out(o, "TotalDPS"), col = col.accent },
		{ label = "Mirage / Minion copies", value = out(o, "MirageDPS"), col = col.int },
		{ label = "Culling", value = out(o, "CullingDPS"), col = col.physical },
		{ label = "Ignite", value = ign, col = col.fire },
		{ label = "Bleed", value = bleed, col = col.life },
		{ label = "Poison", value = poison, col = col.dex },
		{ label = "Impale", value = out(o, "ImpaleDPS"), col = col.warn },
		{ label = "Other DoT", value = otherDot, col = col.chaos },
	}
	local shown, total = { }, 0
	for _, s in ipairs(segs) do if s.value > 0 then t_insert(shown, s); total = total + s.value end end
	local r = m_min(ch / 2, 62)
	local dcx, dcy = cx + r + 4, cy + ch / 2
	Viz.donut(dcx, dcy, r, r * 0.34, shown)
	Viz.text(dcx, dcy - 9, "CENTER", 16, "VAR BOLD", Viz.num(total), col.text)
	local lx = cx + r * 2 + 24
	local lw = cw - (lx - cx)
	local rowH = m_min(20, ch / m_max(1, #shown))
	local ly = dcy - rowH * #shown / 2
	for i, s in ipairs(shown) do
		local ry = ly + (i - 1) * rowH
		Viz.swatch(lx, ry + 3, s.col)
		Viz.text(lx + 16, ry, "LEFT", 14, "VAR", s.label, col.text)
		Viz.text(lx + lw, ry, "RIGHT", 14, "VAR", string.format("%s  %s", Viz.num(s.value), Viz.hex(col.muted) .. Viz.pct(total > 0 and s.value / total * 100 or 0)), col.text)
	end
	if #shown == 0 then
		Viz.text(lx, dcy - 8, "LEFT", 14, "VAR", "No damage calculated for the main skill", col.muted)
	end
end

function OverviewTabClass:CardOffense(x, y, w, h, o)
	local cx, cy, cw = Viz.card(x, y, w, h, "Offence", self:MainSkillName())
	local rows = {
		{ "Crit chance", Viz.pct(out(o, "CritChance"), 1), out(o, "CritChance") / 100, col.lightning },
		{ "Hit chance", Viz.pct(out(o, "HitChance")), out(o, "HitChance") / 100, col.accent },
		{ "Crit multiplier", Viz.pct(out(o, "CritMultiplier") * 100), m_min(1, out(o, "CritMultiplier") / 6), col.fire },
		{ "Speed (uses/sec)", string.format("%.2f", out(o, "Speed")), m_min(1, out(o, "Speed") / 10), col.dex },
	}
	local rowH = (h - 52) / (#rows + 1)
	for i, r in ipairs(rows) do
		local ry = cy + (i - 1) * rowH
		Viz.text(cx, ry, "LEFT", 14, "VAR", r[1], col.muted)
		Viz.text(cx + cw, ry, "RIGHT", 14, "VAR BOLD", r[2], col.text)
		Viz.bar(cx, ry + 18, cw, 5, r[3], r[4])
	end
	local ry = cy + #rows * rowH
	Viz.text(cx, ry, "LEFT", 14, "VAR", string.format("Average hit %s   |   AoE radius %.1fm", Viz.num(out(o, "AverageDamage")), out(o, "AreaOfEffectRadiusMetres")), col.muted)
end

function OverviewTabClass:CardResources(x, y, w, h, o)
	local cx, cy, cw = Viz.card(x, y, w, h, "Resources & Recovery")
	local pools = {
		{ "Life", out(o, "Life"), out(o, "LifeUnreserved"), col.life },
		{ "Energy Shield", out(o, "EnergyShield"), out(o, "EnergyShield"), col.es },
		{ "Mana", out(o, "Mana"), out(o, "ManaUnreserved"), col.mana },
	}
	local rowH = 34
	for i, p in ipairs(pools) do
		local ry = cy + (i - 1) * rowH
		local total, free = p[2], p[3]
		Viz.text(cx, ry, "LEFT", 14, "VAR", p[1], p[4])
		local label = Viz.num(total)
		if total > 0 and free < total then
			label = Viz.num(free) .. Viz.hex(col.muted) .. " free of " .. Viz.num(total)
		end
		Viz.text(cx + cw, ry, "RIGHT", 14, "VAR BOLD", label, free < 0 and col.bad or col.text)
		Viz.bar(cx, ry + 18, cw, 7, total > 0 and m_max(0, free) / total or 0, p[4])
	end
	local ry = cy + #pools * rowH + 2
	local rec = {
		{ "Life leech", out(o, "LifeLeechGainRate") },
		{ "Life regen", out(o, "LifeRegenRecovery") },
		{ "ES regen", out(o, "EnergyShieldRegenRecovery") },
		{ "Mana regen", out(o, "ManaRegenRecovery") },
	}
	local half = cw / 2
	for i, r in ipairs(rec) do
		local rx = cx + ((i - 1) % 2) * half
		local rry = ry + m_floor((i - 1) / 2) * 18
		Viz.text(rx, rry, "LEFT", 13, "VAR", r[1], col.muted)
		Viz.text(rx + half - 10, rry, "RIGHT", 13, "VAR BOLD", Viz.num(r[2], 1) .. "/s", r[2] > 0 and col.text or col.muted)
	end
end

function OverviewTabClass:CardAttributes(x, y, w, h, o)
	local cx, cy, cw = Viz.card(x, y, w, h, "Attributes", "line = highest requirement")
	local attrs = { { "Str", "Strength", col.str }, { "Dex", "Dexterity", col.dex }, { "Int", "Intelligence", col.int } }
	local maxV = 1
	for _, a in ipairs(attrs) do maxV = m_max(maxV, out(o, a[1]), out(o, "Req" .. a[1])) end
	maxV = maxV * 1.1
	local rowH = (h - 52) / #attrs
	for i, a in ipairs(attrs) do
		local ry = cy + (i - 1) * rowH
		local have, need = out(o, a[1]), out(o, "Req" .. a[1])
		Viz.text(cx, ry, "LEFT", 14, "VAR", a[2], a[3])
		local label = string.format("%d", have)
		if need > 0 then label = label .. Viz.hex(col.muted) .. string.format("  (needs %d)", need) end
		Viz.text(cx + cw, ry, "RIGHT", 14, "VAR BOLD", label, need > have and col.bad or col.text)
		Viz.bar(cx, ry + 19, cw, 8, have / maxV, a[3])
		if need > 0 then Viz.rect(cx + cw * need / maxV - 1, ry + 16, 2, 14, col.text, 0.7) end
	end
end

function OverviewTabClass:CardHealth(x, y, w, h, o)
	local checks = self:HealthChecks(o)
	local bad = 0
	for _, c in ipairs(checks) do if c.level ~= "good" then bad = bad + 1 end end
	local cx, cy, cw, ch = Viz.card(x, y, w, h, "Build Health", bad == 0 and "all good" or (bad .. " to look at"))
	-- Problems first
	local order = { bad = 1, warn = 2, good = 3 }
	table.sort(checks, function(a, b) return order[a.level] < order[b.level] end)
	local rowH = 19
	local maxRows = m_floor(ch / rowH)
	for i, c in ipairs(checks) do
		if i > maxRows then
			Viz.text(cx, cy + (i - 1) * rowH, "LEFT", 13, "VAR", string.format("+ %d more", #checks - maxRows + 1), col.muted)
			break
		end
		local ry = cy + (i - 1) * rowH
		local c3 = c.level == "bad" and col.bad or (c.level == "warn" and col.warn or col.good)
		local icon = c.level == "good" and "+" or (c.level == "warn" and "!" or "x")
		Viz.softRect(cx, ry + 2, 14, 14, c3)
		Viz.text(cx + 7, ry + 1, "CENTER", 13, "VAR BOLD", icon, col.bg)
		local str = c.text
		str = Viz.fit(14, "VAR", str, cw - 22)
		Viz.text(cx + 22, ry + 1, "LEFT", 14, "VAR", str, c.level == "good" and col.muted or col.text)
	end
end

-- Main draw ------------------------------------------------------------------
function OverviewTabClass:Draw(viewPort, inputEvents)
	self.x, self.y, self.width, self.height = viewPort.x, viewPort.y, viewPort.width, viewPort.height

	for id, event in ipairs(inputEvents) do
		if event.type == "KeyUp" and (event.key == "WHEELUP" or event.key == "WHEELDOWN") then
			local cursorX, cursorY = GetCursorPos()
			if cursorX >= viewPort.x and cursorY >= viewPort.y and cursorX < viewPort.x + viewPort.width and cursorY < viewPort.y + viewPort.height then
				self.scrollY = self.scrollY + (event.key == "WHEELUP" and -60 or 60)
				inputEvents[id] = nil
			end
		end
	end
	local maxScroll = m_max(0, self.contentHeight - viewPort.height)
	self.scrollY = m_max(0, m_min(self.scrollY, maxScroll))

	local o = self.build.calcsTab.mainOutput or { }

	SetViewport(viewPort.x, viewPort.y, viewPort.width, viewPort.height)
	Viz.rect(0, 0, viewPort.width, viewPort.height, col.bg)

	local pad = 16
	local x, w = pad, viewPort.width - pad * 2
	local y = pad - self.scrollY

	y = y + self:DrawHeader(x, y, w, o) + 10
	y = y + self:DrawTiles(x, y, w, o) + 14

	local cols = viewPort.width >= 1150 and 3 or (viewPort.width >= 700 and 2 or 1)
	local gap = 14
	local cardW = (w - gap * (cols - 1)) / cols
	local cards = {
		{ fn = self.CardResists, h = 196 },
		{ fn = self.CardMaxHit, h = 196 },
		{ fn = self.CardAvoidance, h = 196 },
		{ fn = self.CardDamage, h = 196 },
		{ fn = self.CardOffense, h = 196 },
		{ fn = self.CardResources, h = 196 },
		{ fn = self.CardHealth, h = 196 },
		{ fn = self.CardAttributes, h = 196 },
	}
	local rowY, rowH = y, 0
	for i, card in ipairs(cards) do
		local c = (i - 1) % cols
		if c == 0 and i > 1 then rowY = rowY + rowH + gap; rowH = 0 end
		local ok, err = pcall(card.fn, self, x + c * (cardW + gap), rowY, cardW, card.h, o)
		if not ok then
			Viz.text(x + c * (cardW + gap) + 12, rowY + 40, "LEFT", 14, "VAR", "Error: " .. tostring(err), col.bad)
		end
		rowH = m_max(rowH, card.h)
	end
	local bottom = rowY + rowH + pad
	self.contentHeight = bottom + self.scrollY

	-- Scroll hint
	if maxScroll > 0 then
		local trackH = viewPort.height - 8
		local thumbH = m_max(30, trackH * viewPort.height / self.contentHeight)
		local thumbY = 4 + (trackH - thumbH) * (self.scrollY / maxScroll)
		Viz.rect(viewPort.width - 6, 4, 3, trackH, col.track)
		Viz.rect(viewPort.width - 6, thumbY, 3, thumbH, col.muted)
	end

	SetDrawColor(1, 1, 1)
	SetViewport()
end

return OverviewTabClass
