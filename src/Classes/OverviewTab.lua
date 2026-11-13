-- Path of Building - Agent Edition
--
-- Class: Overview Tab
-- A dashboard of the current build drawn as infographics. Every card shows
-- details on hover and most open the related tab on click.
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
	self.hot = { }        -- interactive regions registered this frame
	self.lastHot = { }    -- regions from the previous frame (used for input)
	self.tooltip = new("Tooltip")
end)

local DAMAGE_TYPES = { "Physical", "Fire", "Cold", "Lightning", "Chaos" }
local ELEMENTS = {
	{ key = "Fire", label = "Fire", col = col.fire },
	{ key = "Cold", label = "Cold", col = col.cold },
	{ key = "Lightning", label = "Lightning", col = col.lightning },
	{ key = "Chaos", label = "Chaos", col = col.chaos },
}
local TAB_NAMES = { CALCS = "Calcs", SKILLS = "Skills", ITEMS = "Items", TREE = "Tree", CONFIG = "Configuration" }

local function out(o, k) return tonumber(o and o[k]) or 0 end
local function fmtInt(v) return formatNumSep(tostring(m_floor((tonumber(v) or 0) + 0.5))) end

-- Interaction ---------------------------------------------------------------
-- Register a hover/click region (coordinates relative to the tab viewport).
-- tip: list of lines, or function(tooltip) that fills a Tooltip.
-- click: function, or a view name such as "CALCS".
function OverviewTabClass:Hot(id, x, y, w, h, tip, click)
	t_insert(self.hot, { id = id, x = x, y = y, w = w, h = h, tip = tip, click = click })
end

function OverviewTabClass:IsHot(id)
	return self.hoverId == id
end

-- The innermost (last registered) region under the cursor.
local function regionAt(list, mx, my)
	for i = #list, 1, -1 do
		local r = list[i]
		if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then return r end
	end
end

function OverviewTabClass:RunClick(click)
	if type(click) == "function" then
		click()
	elseif type(click) == "string" then
		self.build.viewMode = click
	end
end

-- Card wrapper: draws the card and registers it as a region.
function OverviewTabClass:Card(id, x, y, w, h, title, note, tip, click)
	local hovered = self:IsHot(id) and click
	local cx, cy, cw, ch = Viz.card(x, y, w, h, title, note)
	if hovered then Viz.outline(x, y, w, h, col.accent) end
	if click then
		local hint = "open " .. (TAB_NAMES[click] or "")
		if type(click) == "string" and hovered then
			Viz.text(x + w - 12, y + h - 18, "RIGHT", 12, "VAR", hint .. " >", col.accent)
		end
	end
	self:Hot(id, x, y, w, h, tip, click)
	return cx, cy, cw, ch
end

-- Data helpers -------------------------------------------------------------
function OverviewTabClass:MainSkill()
	local ok, skill = pcall(function() return self.build.calcsTab.mainEnv.player.mainSkill end)
	return ok and skill or nil
end

function OverviewTabClass:MainSkillName()
	local ok, name = pcall(function() return self:MainSkill().activeEffect.grantedEffect.name end)
	return ok and name or nil
end

-- Damage per type for the main skill: hits (crit-weighted, after enemy
-- resistances, including conversion) scaled to hit DPS + mirage DPS, plus
-- ailments attributed to their type (ignite = fire, bleed = physical,
-- poison = chaos). Returns { [type] = { hit = n, ailment = n } }, totals.
function OverviewTabClass:DamageByType(o)
	local res = { }
	for _, t in ipairs(DAMAGE_TYPES) do res[t] = { hit = 0, ailment = 0 } end
	local passes = { }
	if o.MainHand then t_insert(passes, o.MainHand) end
	if o.OffHand then t_insert(passes, o.OffHand) end
	if #passes == 0 then t_insert(passes, o) end
	local avg, total = { }, 0
	for _, t in ipairs(DAMAGE_TYPES) do avg[t] = 0 end
	for _, p in ipairs(passes) do
		local cc = out(p, "CritChance") / 100
		for _, t in ipairs(DAMAGE_TYPES) do
			local v = out(p, t .. "HitAverage") * (1 - cc) + out(p, t .. "CritAverage") * cc
			if v == 0 then v = out(p, t .. "HitAverage") end
			avg[t] = avg[t] + v
			total = total + v
		end
	end
	local hitDps = out(o, "TotalDPS") + out(o, "MirageDPS") + out(o, "CullingDPS")
	if total > 0 then
		for _, t in ipairs(DAMAGE_TYPES) do res[t].hit = hitDps * avg[t] / total end
	end
	res.Fire.ailment = out(o, "IgniteDPS")
	res.Physical.ailment = out(o, "BleedDPS")
	res.Chaos.ailment = out(o, "PoisonDPS")
	local sum = 0
	for _, t in ipairs(DAMAGE_TYPES) do sum = sum + res[t].hit + res[t].ailment end
	return res, sum, total > 0
end

-- Build-health checklist: { level = "good"|"warn"|"bad", text, tab }
function OverviewTabClass:HealthChecks(o)
	local checks = { }
	local function add(level, text, tab) t_insert(checks, { level = level, text = text, tab = tab }) end

	local uncapped = { }
	for _, e in ipairs(ELEMENTS) do
		if e.key ~= "Chaos" then
			local v = out(o, e.key .. "Resist")
			if v < 75 then t_insert(uncapped, string.format("%s %d%%", e.label, v)) end
		end
	end
	if #uncapped > 0 then
		add("bad", "Uncapped resistances: " .. table.concat(uncapped, ", "), "ITEMS")
	else
		add("good", "Elemental resistances capped", "CALCS")
	end
	local chaos = out(o, "ChaosResist")
	if chaos < 0 then add("bad", string.format("Negative chaos resistance (%d%%)", chaos), "ITEMS")
	elseif chaos < 30 then add("warn", string.format("Low chaos resistance (%d%%)", chaos), "ITEMS")
	else add("good", string.format("Chaos resistance %d%%", chaos), "CALCS") end

	local hits, sum, n = { }, 0, 0
	for _, t in ipairs(DAMAGE_TYPES) do
		local v = out(o, t .. "MaximumHitTaken")
		if v > 0 then hits[t] = v; sum = sum + v; n = n + 1 end
	end
	if n > 1 then
		local weakest, wv
		for t, v in pairs(hits) do if not wv or v < wv then weakest, wv = t, v end end
		if wv < (sum / n) * 0.55 then
			add("warn", string.format("Weak to %s hits (max %s vs avg %s)", weakest:lower(), Viz.num(wv), Viz.num(sum / n)), "CALCS")
		end
	end

	if out(o, "ManaUnreserved") < 0 then
		add("bad", string.format("Mana over-reserved by %s", Viz.num(-out(o, "ManaUnreserved"))), "SKILLS")
	end
	local supp = out(o, "EffectiveSpellSuppressionChance")
	if supp >= 100 then add("good", "Spell suppression capped", "CALCS")
	elseif supp >= 50 then add("warn", string.format("Spell suppression %d%% (not capped)", supp), "TREE") end

	if out(o, "LifeLeechGainRate") <= 0 and out(o, "LifeRegenRecovery") <= 0 and out(o, "EnergyShieldRegenRecovery") <= 0 and out(o, "Life") > 1 then
		add("warn", "No life leech or regeneration", "ITEMS")
	end
	for _, ail in ipairs({ { "Freeze", "FreezeAvoidChance" }, { "Stun", "StunAvoidChance" } }) do
		local v = out(o, ail[2])
		if ail[1] == "Freeze" and v < 100 and out(o, "Life") > 1 then
			add("warn", string.format("Not freeze immune (%d%% avoid)", v), "ITEMS")
		end
	end

	for _, r in ipairs({ { "Str", "Strength" }, { "Dex", "Dexterity" }, { "Int", "Intelligence" } }) do
		local have, need = out(o, r[1]), out(o, "Req" .. r[1])
		if need > have then add("bad", string.format("%s requirement not met (%d / %d)", r[2], have, need), "ITEMS") end
	end

	for _, line in pairs(self.build.controls.warnings and self.build.controls.warnings.lines or { }) do
		add("warn", (tostring(line):gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", "")), "TREE")
	end
	return checks
end

-- Header and tiles -----------------------------------------------------------
function OverviewTabClass:DrawHeader(x, y, w, o)
	local spec = self.build.spec
	Viz.text(x, y, "LEFT", 26, "VAR BOLD", Viz.fit(26, "VAR BOLD", self.build.buildName or "Unnamed build", w), col.text)
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
	for _, t in ipairs(DAMAGE_TYPES) do
		local v = out(o, t .. "MaximumHitTaken")
		if v > 0 then t_insert(hits, { t = t, v = v }) end
	end
	table.sort(hits, function(a, b) return a.v < b.v end)
	local weakest = hits[1]
	local pool = out(o, "Life") + out(o, "EnergyShield")
	local ms = out(o, "EffectiveMovementSpeedMod")

	local tiles = {
		{ id = "tDps", label = "Combined DPS", value = Viz.num(out(o, "CombinedDPS")), sub = "Hit " .. Viz.num(out(o, "TotalDPS")) .. "  |  DoT " .. Viz.num(out(o, "TotalDotDPS")), c = col.accent, click = "CALCS",
			tip = { "^7Combined DPS: " .. fmtInt(out(o, "CombinedDPS")), "^8Hits, mirage/minion copies, culling and damage over time", "^8for the main skill against your configured enemy." } },
		{ id = "tEhp", label = "Effective Hit Pool", value = Viz.num(out(o, "TotalEHP")), sub = string.format("Armour %s  |  Evasion %s", Viz.num(out(o, "Armour")), Viz.num(out(o, "Evasion"))), c = col.good, click = "CALCS",
			tip = { "^7Effective Hit Pool: " .. fmtInt(out(o, "TotalEHP")), "^8How much raw damage it takes to kill you, averaged over", "^8damage types, after mitigation and avoidance." } },
		{ id = "tPool", label = "Life + Energy Shield", value = Viz.num(pool), sub = string.format("Life %s  |  ES %s", Viz.num(out(o, "Life")), Viz.num(out(o, "EnergyShield"))), c = col.life, click = "CALCS",
			tip = { "^7Life: " .. fmtInt(out(o, "Life")) .. "   Energy Shield: " .. fmtInt(out(o, "EnergyShield")), "^7Mana: " .. fmtInt(out(o, "Mana")) .. " (" .. fmtInt(out(o, "ManaUnreserved")) .. " unreserved)" } },
		{ id = "tHit", label = "Weakest Max Hit", value = weakest and Viz.num(weakest.v) or "-", sub = weakest and (weakest.t .. " damage") or "", c = weakest and col[weakest.t:lower()] or col.muted, click = "CALCS",
			tip = function(tt)
				tt:AddLine(16, "^7Biggest single hit you survive:")
				for _, h in ipairs(hits) do tt:AddLine(14, string.format("%s%s: ^7%s", Viz.hex(col[h.t:lower()]), h.t, fmtInt(h.v))) end
			end },
		{ id = "tMove", label = "Movement Speed", value = string.format("%+d%%", m_floor((ms - 1) * 100 + 0.5)), sub = string.format("Charges %d/%d/%d (E/F/P)", out(o, "EnduranceCharges"), out(o, "FrenzyCharges"), out(o, "PowerCharges")), c = col.dex, click = "CONFIG",
			tip = { "^7Effective movement speed modifier: " .. string.format("%.2fx", ms), "^8Charges and buffs depend on the Configuration tab." } },
	}
	local gap = 12
	local perRow = w >= 1000 and #tiles or (w >= 620 and 3 or 2)
	local rows = math.ceil(#tiles / perRow)
	local tw = (w - gap * (perRow - 1)) / perRow
	local th = 84
	for i, t in ipairs(tiles) do
		local tx = x + ((i - 1) % perRow) * (tw + gap)
		local ty = y + m_floor((i - 1) / perRow) * (th + gap)
		local inner = tw - 28
		Viz.softRect(tx, ty, tw, th, self:IsHot(t.id) and col.cardHi or col.card)
		Viz.outline(tx, ty, tw, th, self:IsHot(t.id) and col.accent or col.border)
		Viz.rect(tx, ty + 8, 3, th - 16, t.c)
		Viz.text(tx + 16, ty + 10, "LEFT", 14, "VAR", Viz.fit(14, "VAR", t.label:upper(), inner), col.muted)
		Viz.text(tx + 16, ty + 28, "LEFT", 30, "VAR BOLD", t.value, col.text)
		Viz.text(tx + 16, ty + 62, "LEFT", 13, "VAR", Viz.fit(13, "VAR", t.sub, inner), col.muted)
		self:Hot(t.id, tx, ty, tw, th, t.tip, t.click)
	end
	return rows * th + (rows - 1) * gap
end

-- Cards ---------------------------------------------------------------------
function OverviewTabClass:CardResists(x, y, w, h, o)
	local cx, cy, cw = self:Card("cRes", x, y, w, h, "Resistances", "bar = 0-90%, line = 75% cap", nil, "CALCS")
	local rowH = (h - 52) / 4
	for i, e in ipairs(ELEMENTS) do
		local ry = cy + (i - 1) * rowH
		local v, over, total = out(o, e.key .. "Resist"), out(o, e.key .. "ResistOverCap"), out(o, e.key .. "ResistTotal")
		local scale = 90
		Viz.text(cx, ry + 2, "LEFT", 15, "VAR", e.label, e.col)
		local label = Viz.pct(v)
		if over > 0 then label = label .. Viz.hex(col.muted) .. string.format("  (+%d over)", over) end
		local bad = (e.key == "Chaos" and v < 0) or (e.key ~= "Chaos" and v < 75)
		Viz.text(cx + cw, ry + 2, "RIGHT", 15, "VAR BOLD", label, bad and col.bad or col.text)
		local by = ry + 21
		Viz.bar(cx, by, cw, 8, m_max(0, v) / scale, e.col)
		if v < 0 then Viz.rect(cx, by, 3, 8, col.bad) end
		Viz.rect(cx + cw * 75 / scale - 1, by - 3, 2, 14, col.text, 0.65)
		local max = over > 0 and v or nil
		self:Hot("res" .. e.key, cx, ry, cw, rowH, {
			Viz.hex(e.col) .. e.label .. " resistance: ^7" .. v .. "%",
			"^8Total from gear, tree and buffs: ^7" .. total .. "%",
			over > 0 and ("^8Over the cap by ^7" .. over .. "% ^8(cap is " .. max .. "%)") or (bad and "^xF55454Below the cap - fix this first" or "^8At or near the cap"),
			"^8Overcap protects you against curses and exposure.",
		}, "CALCS")
	end
end

function OverviewTabClass:CardMaxHit(x, y, w, h, o)
	local maxV, minV, minT = 1, nil, nil
	for _, t in ipairs(DAMAGE_TYPES) do
		local v = out(o, t .. "MaximumHitTaken")
		maxV = m_max(maxV, v)
		if v > 0 and (not minV or v < minV) then minV, minT = v, t end
	end
	local cx, cy, cw = self:Card("cHit", x, y, w, h, "Max Hit Taken", "biggest hit you survive", nil, "CALCS")
	local rowH = (h - 52) / #DAMAGE_TYPES
	local labelW = 74
	for i, t in ipairs(DAMAGE_TYPES) do
		local ry = cy + (i - 1) * rowH
		local v = out(o, t .. "MaximumHitTaken")
		local c = col[t:lower()]
		Viz.text(cx, ry + 1, "LEFT", 14, "VAR", t, c)
		Viz.bar(cx + labelW, ry + 4, cw - labelW - 56, 9, v / maxV, t == minT and col.bad or c)
		Viz.text(cx + cw, ry + 1, "RIGHT", 14, "VAR BOLD", Viz.num(v), t == minT and col.bad or col.text)
		self:Hot("hit" .. t, cx, ry, cw, rowH, {
			Viz.hex(c) .. t .. ": ^7" .. fmtInt(v) .. " max hit",
			t == minT and "^xF55454Your weakest damage type" or "^8",
			string.format("^8Damage taken multiplier: ^7%.2f", out(o, t .. "TakenHitMult") > 0 and out(o, t .. "TakenHitMult") or 1),
		}, "CALCS")
	end
end

function OverviewTabClass:CardAvoidance(x, y, w, h, o)
	local cx, cy, cw, ch = self:Card("cAvoid", x, y, w, h, "Avoidance & Mitigation", nil, nil, "CALCS")
	local gauges = {
		{ id = "Evade", label = "Evade", v = out(o, "EvadeChance"), c = col.dex, tip = "Chance to evade enemy attacks (not spells)." },
		{ id = "Supp", label = "Suppress", v = out(o, "EffectiveSpellSuppressionChance"), c = col.int, tip = "Chance to take less damage from spell hits." },
		{ id = "Block", label = "Block", v = out(o, "BlockChance"), c = col.str, max = 75, tip = "Chance to block attack hits (cap 75%)." },
		{ id = "SBlock", label = "Spell Block", v = out(o, "SpellBlockChance"), c = col.cold, max = 75, tip = "Chance to block spell hits (cap 75%)." },
		{ id = "PDR", label = "Phys Reduct.", v = out(o, "PhysicalDamageReduction"), c = col.physical, max = 90, tip = "Physical damage reduction from armour etc. (cap 90%)." },
	}
	local slot = cw / #gauges
	local r = m_max(16, m_min(slot / 2 - 6, (ch - 28) / 2))
	for i, g in ipairs(gauges) do
		local gx = cx + slot * (i - 0.5)
		local gy = cy + r + 2
		local hot = self:IsHot("av" .. g.id)
		Viz.ring(gx, gy, hot and r + 2 or r, m_max(5, r * 0.22), g.v / (g.max or 100), g.v > 0 and g.c or col.track)
		Viz.text(gx, gy - 9, "CENTER", 16, "VAR BOLD", Viz.pct(g.v), g.v > 0 and col.text or col.muted)
		Viz.text(gx, gy + r + 6, "CENTER", 13, "VAR", g.label, hot and col.text or col.muted)
		self:Hot("av" .. g.id, gx - slot / 2, cy, slot, ch, { "^7" .. g.label .. ": " .. Viz.pct(g.v, 1), "^8" .. g.tip }, "CALCS")
	end
end

function OverviewTabClass:CardDamageTypes(x, y, w, h, o)
	local res, total, hasHits = self:DamageByType(o)
	local elem = res.Fire.hit + res.Fire.ailment + res.Cold.hit + res.Cold.ailment + res.Lightning.hit + res.Lightning.ailment
	local cx, cy, cw, ch = self:Card("cDType", x, y, w, h, "Damage by Type",
		total > 0 and string.format("%d%% elemental", m_floor(elem / total * 100 + 0.5)) or nil, nil, "CALCS")
	local segs = { }
	for _, t in ipairs(DAMAGE_TYPES) do
		t_insert(segs, { t = t, value = res[t].hit + res[t].ailment, hit = res[t].hit, ailment = res[t].ailment, col = col[t:lower()] })
	end
	local r = m_min(ch / 2, 58)
	local dcx, dcy = cx + r + 2, cy + ch / 2
	Viz.donut(dcx, dcy, r, r * 0.34, segs)
	-- Main type in the middle
	local top
	for _, s in ipairs(segs) do if not top or s.value > top.value then top = s end end
	if total > 0 then
		Viz.text(dcx, dcy - 15, "CENTER", 16, "VAR BOLD", Viz.pct(top.value / total * 100), col.text)
		Viz.text(dcx, dcy + 3, "CENTER", 13, "VAR", top.t, top.col)
	end
	local lx = cx + r * 2 + 20
	local lw = cw - (lx - cx)
	local rowH = m_min(24, ch / #segs)
	local ly = dcy - rowH * #segs / 2
	for i, s in ipairs(segs) do
		local ry = ly + (i - 1) * rowH
		local share = total > 0 and s.value / total or 0
		Viz.text(lx, ry, "LEFT", 14, "VAR", s.t, s.value > 0 and s.col or col.muted)
		Viz.text(lx + lw, ry, "RIGHT", 14, "VAR", Viz.num(s.value) .. "  " .. Viz.hex(col.muted) .. Viz.pct(share * 100), s.value > 0 and col.text or col.muted)
		Viz.bar(lx, ry + 17, lw, 4, share, s.col)
		local lines = { Viz.hex(s.col) .. s.t .. " damage: ^7" .. fmtInt(s.value) .. " DPS (" .. Viz.pct(share * 100, 1) .. ")" }
		if s.hit > 0 then t_insert(lines, "^8From hits: ^7" .. fmtInt(s.hit)) end
		if s.ailment > 0 then
			local ail = s.t == "Fire" and "Ignite" or (s.t == "Physical" and "Bleed" or "Poison")
			t_insert(lines, "^8From " .. ail .. ": ^7" .. fmtInt(s.ailment))
		end
		t_insert(lines, "^8Hits include conversion and enemy resistances,")
		t_insert(lines, "^8weighted by crit chance.")
		self:Hot("dt" .. s.t, lx, ry, lw, rowH, lines, "CALCS")
	end
	if not hasHits and total == 0 then
		Viz.text(lx, dcy - 8, "LEFT", 14, "VAR", "No hit damage for the main skill", col.muted)
	end
end

function OverviewTabClass:CardDamageSources(x, y, w, h, o)
	local cx, cy, cw, ch = self:Card("cDSrc", x, y, w, h, "Damage Sources", Viz.num(out(o, "CombinedDPS")) .. " combined", nil, "CALCS")
	local ign, bleed, poison = out(o, "IgniteDPS"), out(o, "BleedDPS"), out(o, "PoisonDPS")
	local otherDot = m_max(0, out(o, "TotalDotDPS") - ign - bleed - poison)
	local segs = {
		{ label = "Hits", value = out(o, "TotalDPS"), col = col.accent, tip = "Direct hits from the main skill." },
		{ label = "Mirage / copies", value = out(o, "MirageDPS"), col = col.int, tip = "Mirage Archer, Mirage Warriors and similar copies." },
		{ label = "Culling", value = out(o, "CullingDPS"), col = col.physical, tip = "Value of culling strike (killing low-life enemies)." },
		{ label = "Ignite", value = ign, col = col.fire, tip = "Fire damage over time from ignite." },
		{ label = "Bleed", value = bleed, col = col.life, tip = "Physical damage over time from bleeding." },
		{ label = "Poison", value = poison, col = col.dex, tip = "Chaos damage over time from poison." },
		{ label = "Impale", value = out(o, "ImpaleDPS"), col = col.warn, tip = "Stored physical damage released by impale." },
		{ label = "Other DoT", value = otherDot, col = col.chaos, tip = "Skill damage over time and other sources." },
	}
	local shown, total = { }, 0
	for _, s in ipairs(segs) do if s.value > 0 then t_insert(shown, s); total = total + s.value end end
	local r = m_min(ch / 2, 58)
	local dcx, dcy = cx + r + 2, cy + ch / 2
	Viz.donut(dcx, dcy, r, r * 0.34, shown)
	Viz.text(dcx, dcy - 9, "CENTER", 16, "VAR BOLD", Viz.num(total), col.text)
	local lx = cx + r * 2 + 20
	local lw = cw - (lx - cx)
	local rowH = m_min(20, ch / m_max(1, #shown))
	local ly = dcy - rowH * #shown / 2
	for i, s in ipairs(shown) do
		local ry = ly + (i - 1) * rowH
		Viz.swatch(lx, ry + 3, s.col)
		Viz.text(lx + 16, ry, "LEFT", 14, "VAR", s.label, col.text)
		Viz.text(lx + lw, ry, "RIGHT", 14, "VAR", Viz.num(s.value) .. "  " .. Viz.hex(col.muted) .. Viz.pct(total > 0 and s.value / total * 100 or 0), col.text)
		self:Hot("src" .. i, lx, ry, lw, rowH, { "^7" .. s.label .. ": " .. fmtInt(s.value) .. " DPS", "^8" .. s.tip }, "CALCS")
	end
	if #shown == 0 then
		Viz.text(lx, dcy - 8, "LEFT", 14, "VAR", "No damage calculated for the main skill", col.muted)
	end
end

function OverviewTabClass:CardOffense(x, y, w, h, o)
	local cx, cy, cw = self:Card("cOff", x, y, w, h, "Offence", self:MainSkillName(), nil, "CALCS")
	local rows = {
		{ "Crit chance", Viz.pct(out(o, "CritChance"), 1), out(o, "CritChance") / 100, col.lightning, "Chance for a hit to crit (after accuracy)." },
		{ "Hit chance", Viz.pct(out(o, "HitChance")), out(o, "HitChance") / 100, col.accent, "Chance to hit the enemy (accuracy vs evasion)." },
		{ "Crit multiplier", Viz.pct(out(o, "CritMultiplier") * 100), m_min(1, out(o, "CritMultiplier") / 6), col.fire, "Damage multiplier on critical strikes." },
		{ "Speed (uses/sec)", string.format("%.2f", out(o, "Speed")), m_min(1, out(o, "Speed") / 10), col.dex, "Attacks or casts per second." },
	}
	local rowH = (h - 52) / (#rows + 1)
	for i, r in ipairs(rows) do
		local ry = cy + (i - 1) * rowH
		Viz.text(cx, ry, "LEFT", 14, "VAR", r[1], col.muted)
		Viz.text(cx + cw, ry, "RIGHT", 14, "VAR BOLD", r[2], col.text)
		Viz.bar(cx, ry + 18, cw, 5, r[3], r[4])
		self:Hot("off" .. i, cx, ry, cw, rowH, { "^7" .. r[1] .. ": " .. r[2], "^8" .. r[5] }, "CALCS")
	end
	local ry = cy + #rows * rowH
	Viz.text(cx, ry, "LEFT", 14, "VAR", Viz.fit(14, "VAR", string.format("Average hit %s   |   AoE radius %.1fm", Viz.num(out(o, "AverageDamage")), out(o, "AreaOfEffectRadiusMetres")), cw), col.muted)
end

function OverviewTabClass:CardSkills(x, y, w, h, o)
	local build = self.build
	local groups = build.skillsTab and build.skillsTab.socketGroupList or { }
	local cx, cy, cw, ch = self:Card("cSkills", x, y, w, h, "Skills", "click to set main skill", nil, nil)
	local rowH = 22
	local maxRows = m_floor(ch / rowH)
	local shown = 0
	for i, g in ipairs(groups) do
		if shown >= maxRows then
			Viz.text(cx, cy + shown * rowH, "LEFT", 13, "VAR", string.format("+ %d more (Skills tab)", #groups - shown), col.muted)
			break
		end
		local ry = cy + shown * rowH
		local isMain = build.mainSocketGroup == i
		local hot = self:IsHot("sk" .. i)
		if isMain or hot then
			Viz.softRect(cx - 4, ry - 1, cw + 8, rowH - 2, isMain and col.cardHi or col.track, isMain and 1 or 0.5)
		end
		if isMain then Viz.rect(cx - 4, ry + 1, 3, rowH - 6, col.accent) end
		local label = g.displayLabel or g.label or ("Group " .. i)
		label = label:gsub("%^x%x%x%x%x%x%x", ""):gsub("%^%d", "")
		local nGems = g.gemList and #g.gemList or 0
		local c = (g.enabled == false) and col.muted or (isMain and col.text or col.text)
		Viz.text(cx + 4, ry + 2, "LEFT", 14, isMain and "VAR BOLD" or "VAR", Viz.fit(14, "VAR", label, cw - 70), c)
		Viz.text(cx + cw, ry + 3, "RIGHT", 12, "VAR", (g.slot and (g.slot .. "  ") or "") .. nGems .. " gems", col.muted)
		self:Hot("sk" .. i, cx - 4, ry - 1, cw + 8, rowH - 2, function(tt)
			tt:AddLine(16, "^7" .. label .. (isMain and "  ^x4FD1C2(main skill)" or ""))
			if g.slot then tt:AddLine(14, "^8Socketed in: ^7" .. g.slot) end
			if g.enabled == false then tt:AddLine(14, "^xF5A742Disabled") end
			tt:AddSeparator(10)
			for _, gem in ipairs(g.gemList or { }) do
				local name = gem.nameSpec or (gem.gemData and gem.gemData.name) or "?"
				local gc = gem.enabled == false and "^8" or (gem.gemData and gem.gemData.grantedEffect and gem.gemData.grantedEffect.support and "^x6C8FD9" or "^7")
				tt:AddLine(14, string.format("%s%s  ^8%d/%d", gc, name, gem.level or 0, gem.quality or 0))
			end
			tt:AddSeparator(10)
			tt:AddLine(13, isMain and "^8Click opens the Skills tab" or "^x4FD1C2Click to make this the main skill")
		end, function()
			if build.mainSocketGroup == i then
				build.viewMode = "SKILLS"
			else
				build.mainSocketGroup = i
				build.modFlag = true
				build.buildFlag = true
			end
		end)
		shown = shown + 1
	end
	if #groups == 0 then Viz.text(cx, cy, "LEFT", 14, "VAR", "No skills yet", col.muted) end
end

local GEAR_SLOTS = { "Weapon 1", "Weapon 2", "Helmet", "Body Armour", "Gloves", "Boots", "Amulet", "Ring 1", "Ring 2", "Belt" }
function OverviewTabClass:CardGear(x, y, w, h, o)
	local itemsTab = self.build.itemsTab
	local cx, cy, cw, ch = self:Card("cGear", x, y, w, h, "Gear", "hover for item, click for Items", nil, "ITEMS")
	local cols = cw >= 420 and 2 or 1
	local colW = (cw - (cols - 1) * 12) / cols
	local perCol = math.ceil(#GEAR_SLOTS / cols)
	local rowH = m_min(26, ch / perCol)
	for i, slotName in ipairs(GEAR_SLOTS) do
		local c = m_floor((i - 1) / perCol)
		local r = (i - 1) % perCol
		local gx, gy = cx + c * (colW + 12), cy + r * rowH
		local slot = itemsTab and itemsTab.slots[slotName]
		local item = slot and slot.selItemId and slot.selItemId > 0 and itemsTab.items[slot.selItemId]
		local hot = self:IsHot("gear" .. i)
		if hot then Viz.softRect(gx - 4, gy - 1, colW + 8, rowH - 2, col.track, 0.6) end
		Viz.text(gx, gy + 3, "LEFT", 12, "VAR", slotName:upper(), col.muted)
		local nameX = gx + 82
		if item then
			local name = item.title or item.name or item.baseName or "?"
			Viz.text(nameX, gy + 1, "LEFT", 14, "VAR", (colorCodes[item.rarity] or "^7") .. Viz.fit(14, "VAR", name, colW - 84))
		else
			Viz.text(nameX, gy + 1, "LEFT", 14, "VAR", "empty", col.bad)
		end
		self:Hot("gear" .. i, gx - 4, gy - 1, colW + 8, rowH - 2, function(tt)
			if item then
				itemsTab:AddItemTooltip(tt, item, slot)
			else
				tt:AddLine(16, "^7" .. slotName .. ": ^xF55454empty")
				tt:AddLine(14, "^8Click to open the Items tab")
			end
		end, "ITEMS")
	end
end

function OverviewTabClass:CardResources(x, y, w, h, o)
	local cx, cy, cw = self:Card("cRes2", x, y, w, h, "Resources & Recovery", nil, nil, "CALCS")
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
		if total > 0 and free < total then label = Viz.num(free) .. Viz.hex(col.muted) .. " free of " .. Viz.num(total) end
		Viz.text(cx + cw, ry, "RIGHT", 14, "VAR BOLD", label, free < 0 and col.bad or col.text)
		Viz.bar(cx, ry + 18, cw, 7, total > 0 and m_max(0, free) / total or 0, p[4])
		self:Hot("pool" .. i, cx, ry, cw, rowH, { "^7" .. p[1] .. ": " .. fmtInt(total), "^8Unreserved: ^7" .. fmtInt(free), total > 0 and ("^8Reserved: ^7" .. Viz.pct((total - free) / total * 100)) or "^8" }, "CALCS")
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

function OverviewTabClass:CardAilments(x, y, w, h, o)
	local cx, cy, cw, ch = self:Card("cAil", x, y, w, h, "Ailments & Charges", "avoid chance", nil, "CALCS")
	local ails = {
		{ "Freeze", "FreezeAvoidChance", col.cold }, { "Chill", "ChillAvoidChance", col.cold },
		{ "Shock", "ShockAvoidChance", col.lightning }, { "Ignite", "IgniteAvoidChance", col.fire },
		{ "Bleed", "BleedAvoidChance", col.life }, { "Poison", "PoisonAvoidChance", col.dex },
		{ "Stun", "StunAvoidChance", col.physical }, { "Curses", "CurseEffectOnSelf", col.chaos, curse = true },
	}
	local perRow = 4
	local chipW = (cw - (perRow - 1) * 8) / perRow
	local chipH = 38
	for i, a in ipairs(ails) do
		local gx = cx + ((i - 1) % perRow) * (chipW + 8)
		local gy = cy + m_floor((i - 1) / perRow) * (chipH + 8)
		local v = out(o, a[2])
		local good, label
		if a.curse then
			good = v <= 50 and "good" or (v < 100 and "warn" or "none")
			label = Viz.pct(v) .. " effect"
		else
			good = v >= 100 and "good" or (v > 0 and "warn" or "none")
			label = v >= 100 and "Immune" or Viz.pct(v)
		end
		local c = good == "good" and col.good or (good == "warn" and col.warn or col.muted)
		Viz.softRect(gx, gy, chipW, chipH, col.cardHi)
		Viz.rect(gx, gy + chipH - 3, chipW, 3, c)
		Viz.text(gx + 8, gy + 4, "LEFT", 13, "VAR", a[1], a[3])
		Viz.text(gx + 8, gy + 18, "LEFT", 14, "VAR BOLD", Viz.fit(14, "VAR BOLD", label, chipW - 12), good == "none" and col.muted or col.text)
		self:Hot("ail" .. i, gx, gy, chipW, chipH, a.curse
			and { "^7Curse effect on you: " .. Viz.pct(v), "^8100% is normal; lower is better." }
			or { "^7Avoid " .. a[1]:lower() .. ": " .. Viz.pct(v), v >= 100 and "^x5CD677Immune" or "^8100% means immune." }, "CALCS")
	end
	local ry = cy + 2 * (chipH + 8) + 2
	local charges = {
		{ "Endurance", out(o, "EnduranceCharges"), out(o, "EnduranceChargesMax"), col.str },
		{ "Frenzy", out(o, "FrenzyCharges"), out(o, "FrenzyChargesMax"), col.dex },
		{ "Power", out(o, "PowerCharges"), out(o, "PowerChargesMax"), col.int },
	}
	local cwid = cw / 3
	for i, chg in ipairs(charges) do
		local gx = cx + (i - 1) * cwid
		Viz.text(gx, ry, "LEFT", 13, "VAR", chg[1], chg[4])
		for p = 1, m_max(chg[3], 0) do
			Viz.softRect(gx + (p - 1) * 13, ry + 17, 10, 10, p <= chg[2] and chg[4] or col.track)
		end
		self:Hot("chg" .. i, gx, ry, cwid, 30, { "^7" .. chg[1] .. " charges: " .. chg[2] .. " / " .. chg[3], "^8Active charges are set in the Configuration tab." }, "CONFIG")
	end
end

function OverviewTabClass:CardAttributes(x, y, w, h, o)
	local cx, cy, cw = self:Card("cAttr", x, y, w, h, "Attributes", "line = highest requirement", nil, "TREE")
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
		self:Hot("attr" .. i, cx, ry, cw, rowH, { "^7" .. a[2] .. ": " .. have, "^8Highest requirement from gems/gear: ^7" .. need, have >= need and ("^8Spare: ^7" .. (have - need)) or ("^xF55454Short by " .. (need - have)) }, "TREE")
	end
end

function OverviewTabClass:CardHealth(x, y, w, h, o)
	local checks = self:HealthChecks(o)
	local bad = 0
	for _, c in ipairs(checks) do if c.level ~= "good" then bad = bad + 1 end end
	local cx, cy, cw, ch = self:Card("cHealth", x, y, w, h, "Build Health", bad == 0 and "all good" or (bad .. " to look at"), nil, nil)
	local order = { bad = 1, warn = 2, good = 3 }
	table.sort(checks, function(a, b) return order[a.level] < order[b.level] end)
	local rowH = 19
	local maxRows = m_floor(ch / rowH)
	for i, c in ipairs(checks) do
		local ry = cy + (i - 1) * rowH
		if i >= maxRows and #checks > maxRows then
			Viz.text(cx, ry, "LEFT", 13, "VAR", string.format("+ %d more", #checks - maxRows + 1), col.muted)
			break
		end
		local c3 = c.level == "bad" and col.bad or (c.level == "warn" and col.warn or col.good)
		local icon = c.level == "good" and "+" or (c.level == "warn" and "!" or "x")
		local hot = self:IsHot("hc" .. i)
		if hot then Viz.softRect(cx - 4, ry, cw + 8, rowH, col.track, 0.6) end
		Viz.softRect(cx, ry + 2, 14, 14, c3)
		Viz.text(cx + 7, ry + 1, "CENTER", 13, "VAR BOLD", icon, col.bg)
		Viz.text(cx + 22, ry + 1, "LEFT", 14, "VAR", Viz.fit(14, "VAR", c.text, cw - 22), c.level == "good" and col.muted or col.text)
		self:Hot("hc" .. i, cx - 4, ry, cw + 8, rowH, { "^7" .. c.text, "^8Click to open the " .. (TAB_NAMES[c.tab] or "") .. " tab" }, c.tab)
	end
end

-- Main draw ------------------------------------------------------------------
function OverviewTabClass:Draw(viewPort, inputEvents)
	self.x, self.y, self.width, self.height = viewPort.x, viewPort.y, viewPort.width, viewPort.height
	local cursorX, cursorY = GetCursorPos()
	local mx, my = cursorX - viewPort.x, cursorY - viewPort.y
	local inside = mx >= 0 and my >= 0 and mx < viewPort.width and my < viewPort.height
	local overRegion = inside and regionAt(self.lastHot, mx, my) or nil
	self.hoverId = overRegion and overRegion.id or nil

	for id, event in ipairs(inputEvents) do
		if inside and event.type == "KeyUp" and (event.key == "WHEELUP" or event.key == "WHEELDOWN") then
			self.scrollY = self.scrollY + (event.key == "WHEELUP" and -60 or 60)
			inputEvents[id] = nil
		elseif inside and event.type == "KeyDown" and event.key == "LEFTBUTTON" then
			self.pressId = overRegion and overRegion.click and overRegion.id or nil
			inputEvents[id] = nil
		elseif inside and event.type == "KeyUp" and event.key == "LEFTBUTTON" then
			if overRegion and overRegion.click and overRegion.id == self.pressId then
				self:RunClick(overRegion.click)
			end
			self.pressId = nil
			inputEvents[id] = nil
		end
	end
	local maxScroll = m_max(0, self.contentHeight - viewPort.height)
	self.scrollY = m_max(0, m_min(self.scrollY, maxScroll))

	local o = self.build.calcsTab.mainOutput or { }
	self.hot = { }

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
		{ fn = self.CardDamageTypes, h = 196 },
		{ fn = self.CardDamageSources, h = 196 },
		{ fn = self.CardOffense, h = 196 },
		{ fn = self.CardResists, h = 196 },
		{ fn = self.CardMaxHit, h = 196 },
		{ fn = self.CardAvoidance, h = 196 },
		{ fn = self.CardSkills, h = 210 },
		{ fn = self.CardGear, h = 210 },
		{ fn = self.CardAilments, h = 210 },
		{ fn = self.CardResources, h = 196 },
		{ fn = self.CardAttributes, h = 196 },
		{ fn = self.CardHealth, h = 196 },
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

	if maxScroll > 0 then
		local trackH = viewPort.height - 8
		local thumbH = m_max(30, trackH * viewPort.height / self.contentHeight)
		local thumbY = 4 + (trackH - thumbH) * (self.scrollY / maxScroll)
		Viz.rect(viewPort.width - 6, 4, 3, trackH, col.track)
		Viz.rect(viewPort.width - 6, thumbY, 3, thumbH, col.muted)
	end

	SetDrawColor(1, 1, 1)
	SetViewport()

	-- Regions for next frame's input; tooltip for the region under the cursor now.
	self.lastHot = self.hot
	local tipRegion = inside and regionAt(self.hot, mx, my) or nil
	if tipRegion and tipRegion.tip then
		local tt = self.tooltip
		tt:Clear()
		if type(tipRegion.tip) == "function" then
			local ok, err = pcall(tipRegion.tip, tt)
			if not ok then tt:AddLine(14, "^1" .. tostring(err)) end
		else
			for _, line in ipairs(tipRegion.tip) do
				if line ~= "^8" then tt:AddLine(15, line) end
			end
		end
		SetDrawLayer(nil, 100)
		tt:Draw(viewPort.x + tipRegion.x, viewPort.y + tipRegion.y, tipRegion.w, tipRegion.h, main.viewPort)
		SetDrawLayer(nil, 0)
	end
end

return OverviewTabClass
