-- Path of Building - Agent Edition
--
-- Class: Overview Tab
-- A dashboard of the current build drawn as infographics. Every card shows
-- details on hover and most open the related tab on click.
--
local Viz = LoadModule("Agent/Viz")
local Icons = LoadModule("Agent/IconCache")
local AgentSettings = LoadModule("Agent/Settings")
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
local TAB_NAMES = { ATLAS = "Atlas", CALCS = "Calcs", SKILLS = "Skills", ITEMS = "Items", TREE = "Tree", CONFIG = "Configuration" }

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
-- Player profile (AgentEdition.json), re-read every 2 s so changes made by
-- an AI client (profile_set) show up without reopening anything.
function OverviewTabClass:Profile()
	local now = GetTime()
	if not self.profile or now - (self.profileTime or 0) > 2000 then
		local ok, profile = pcall(AgentSettings.getProfile, main.userPath)
		self.profile = ok and profile or AgentSettings.normalizeProfile(nil)
		self.profileTime = now
	end
	return self.profile
end

local MODE_COLOURS = { trade = col.accent, ssf = col.good, mixed = col.lightning }

function OverviewTabClass:ProfileChips()
	local p = self:Profile()
	local function desc(list, value)
		for _, entry in ipairs(list) do
			if entry.value == value then return entry.desc end
		end
	end
	local currency = { }
	if p.currency.chaos > 0 then t_insert(currency, fmtInt(p.currency.chaos) .. "c") end
	if p.currency.divine > 0 then t_insert(currency, fmtInt(p.currency.divine) .. " div") end
	local chips = {
		{ id = "pfMode", label = AgentSettings.label(AgentSettings.PLAY_MODES, p.playMode), c = MODE_COLOURS[p.playMode] or col.accent,
			tip = { "^7Play mode: " .. AgentSettings.label(AgentSettings.PLAY_MODES, p.playMode), "^8" .. (desc(AgentSettings.PLAY_MODES, p.playMode) or "") } },
		{ id = "pfHardcore", label = p.hardcore and "Hardcore" or "Softcore", c = p.hardcore and col.bad or col.muted,
			tip = { "^7" .. (p.hardcore and "Hardcore: one death moves the character to softcore. The AI puts defences first." or "Softcore: deaths only cost experience.") } },
		{ id = "pfLeague", label = p.league ~= "" and p.league or "Current league", c = col.text,
			tip = { "^7League: " .. (p.league ~= "" and p.league or "not set (AI uses the current challenge league)") } },
		{ id = "pfCurrency", label = #currency > 0 and table.concat(currency, "  ") or "Currency: not set", c = #currency > 0 and col.lightning or col.muted,
			tip = { "^7Currency on hand: " .. (#currency > 0 and table.concat(currency, ", ") or "not set"),
				p.currency.other ~= "" and ("^7Other: " .. p.currency.other) or "^8",
				"^8The AI uses it as the budget for upgrade plans." } },
		{ id = "pfExplain", label = AgentSettings.label(AgentSettings.EXPLANATION_MODES, p.explanationMode), c = col.muted,
			tip = { "^7Explanations: " .. AgentSettings.label(AgentSettings.EXPLANATION_MODES, p.explanationMode),
				"^8" .. (desc(AgentSettings.EXPLANATION_MODES, p.explanationMode) or ""),
				"^8Explained topics: " .. #p.learnedTopics } },
	}
	for _, chip in ipairs(chips) do
		t_insert(chip.tip, "^8")
		if #p.goals > 0 then t_insert(chip.tip, "^7Goals: ^8" .. table.concat(p.goals, ", ")) end
		t_insert(chip.tip, "^xFFB040Click to edit the Agent profile in Options")
		chip.w = Viz.textWidth(14, "VAR", chip.label) + 20
	end
	return chips
end

-- Draws chips right-aligned ending at xRight. Returns total width.
function OverviewTabClass:DrawChips(chips, xRight, y)
	local cx = xRight
	for i = #chips, 1, -1 do
		local chip = chips[i]
		cx = cx - chip.w
		local hovered = self:IsHot(chip.id)
		Viz.softRect(cx, y, chip.w, 24, hovered and col.cardHi or col.card)
		Viz.outline(cx, y, chip.w, 24, hovered and col.accent or Viz.mix(col.border, chip.c, 0.35))
		Viz.text(cx + 10, y + 5, "LEFT", 14, "VAR", chip.label, chip.c)
		self:Hot(chip.id, cx, y, chip.w, 24, chip.tip, function() main:OpenOptionsPopup() end)
		cx = cx - 6
	end
	return xRight - cx - 6
end

-- Update banner ---------------------------------------------------------------
-- Shown when a newer PoB Agent Edition release is out (Agent/Update.lua keeps
-- the daily check in AgentEdition.json). Re-read every 5 s.
function OverviewTabClass:UpdateInfo()
	local now = GetTime()
	if self.updateTime == nil or now - self.updateTime > 5000 then
		self.updateTime = now
		local ok, Update = pcall(LoadModule, "Agent/Update")
		self.updateInfo = nil
		if ok and main.userPath then
			local okA, info = pcall(Update.available, main.userPath)
			if okA and info then
				info.kind = "release"
				self.updateInfo = info
			elseif Update.installType() == "git" then
				local okB, base = pcall(Update.baseNewer, main.userPath)
				local st = Update.state(main.userPath)
				if okB and base and (tonumber(st.snoozeUntil) or 0) <= os.time() then
					self.updateInfo = { kind = "base", version = base, current = launch.versionNumber }
				end
			end
		end
	end
	return self.updateInfo
end

function OverviewTabClass:OpenUpdateNotes(info)
	local Update = LoadModule("Agent/Update")
	local width = 640
	local lines = { }
	for para in (Update.plainNotes(info.notes) .. "\n"):gmatch("([^\n]*)\n") do
		if para == "" then
			t_insert(lines, "")
		else
			for _, l in ipairs(main:WrapString(para, 16, width - 40)) do t_insert(lines, l) end
		end
	end
	while lines[1] == "" do table.remove(lines, 1) end
	local maxLines = 26
	if #lines > maxLines then
		for i = #lines, maxLines + 1, -1 do lines[i] = nil end
		t_insert(lines, "^8... more on the release page")
	end
	local controls = { }
	for i, l in ipairs(lines) do
		controls["l" .. i] = new("LabelControl", { "TOPLEFT", nil, "TOPLEFT" }, { 20, 20 + (i - 1) * 17, 0, 16 }, "^7" .. l)
	end
	local height = 80 + #lines * 17
	controls.update = new("ButtonControl", { "BOTTOM", nil, "BOTTOM" }, { -150, -10, 120, 20 }, "Update now", function()
		main:ClosePopup()
		self:StartUpdate(info)
	end)
	controls.page = new("ButtonControl", { "BOTTOM", nil, "BOTTOM" }, { 0, -10, 140, 20 }, "Release page", function()
		if info.url then OpenURL(info.url) end
	end)
	controls.close = new("ButtonControl", { "BOTTOM", nil, "BOTTOM" }, { 150, -10, 120, 20 }, "Close", function()
		main:ClosePopup()
	end)
	main:OpenPopup(width, height, "What's new in v" .. info.version, controls, nil, nil, "close")
end

function OverviewTabClass:StartUpdate(info)
	if self.build.unsaved then
		main:OpenMessagePopup("Save first", "This build has unsaved changes.\nSave it (Ctrl+S) before updating: PoB closes during the update.")
		return
	end
	local Update = LoadModule("Agent/Update")
	main:OpenConfirmPopup("Update PoB Agent Edition",
		"PoB closes, updates to v" .. info.version .. " and starts again.\nYour builds and settings are kept, and the old version is kept as a backup\n(tools\\update.ps1 -Rollback returns to it).",
		"Update now", function()
			local ok, err = Update.startUpdater("-Yes -Version " .. info.version)
			if ok then Exit() else main:OpenMessagePopup("Update", "Could not start the updater: " .. tostring(err)) end
		end)
end

function OverviewTabClass:DrawUpdateBanner(x, y, w)
	local info = self:UpdateInfo()
	if not info then return 0 end
	local Update = LoadModule("Agent/Update")
	local h = 34
	local c = info.kind == "release" and col.accent or col.muted
	Viz.softRect(x, y, w, h, Viz.mix(col.card, c, 0.12))
	Viz.outline(x, y, w, h, Viz.mix(col.border, c, 0.6))
	local buttons
	if info.kind == "release" then
		buttons = {
			{ id = "updNotes", label = "What's new", click = function() self:OpenUpdateNotes(info) end },
			{ id = "updNow", label = "Update now", strong = true, click = function() self:StartUpdate(info) end },
			{ id = "updLater", label = "Later", click = function() Update.later(main.userPath); self.updateTime = nil end },
			{ id = "updSkip", label = "Skip this version", click = function() Update.skip(main.userPath, info.version); self.updateTime = nil end },
		}
	else
		buttons = { { id = "updLater", label = "Later", click = function() Update.later(main.userPath); self.updateTime = nil end } }
	end
	local bx = x + w - 6
	for i = #buttons, 1, -1 do
		local b = buttons[i]
		local bw = Viz.textWidth(14, "VAR", b.label) + 18
		bx = bx - bw
		local hot = self:IsHot(b.id)
		Viz.softRect(bx, y + 5, bw, 24, hot and col.cardHi or col.card)
		Viz.outline(bx, y + 5, bw, 24, (hot or b.strong) and col.accent or col.border)
		Viz.text(bx + 9, y + 9, "LEFT", 14, "VAR", b.label, b.strong and col.accent or col.text)
		self:Hot(b.id, bx, y + 5, bw, 24, nil, b.click)
		bx = bx - 6
	end
	local msg
	if info.kind == "release" then
		msg = string.format("PoB Agent Edition v%s is available (you have v%s).", info.version, info.current)
	else
		msg = string.format("Developer: official PoB v%s is newer than our base v%s. Run tools\\update-pob.ps1 -Check.", info.version, tostring(info.current))
	end
	Viz.text(x + 12, y + 9, "LEFT", 15, "VAR", Viz.fit(15, "VAR", msg, bx - x - 18), info.kind == "release" and col.text or col.muted)
	return h
end

function OverviewTabClass:DrawHeader(x, y, w, o)
	local spec = self.build.spec
	local chips = self:ProfileChips()
	local chipsW = -6
	for _, chip in ipairs(chips) do chipsW = chipsW + chip.w + 6 end
	local chipsInline = chipsW <= w * 0.55
	local titleW = chipsInline and (w - chipsW - 16) or w
	if chipsInline then self:DrawChips(chips, x + w, y + 2) end
	Viz.text(x, y, "LEFT", 26, "VAR BOLD", Viz.fit(26, "VAR BOLD", self.build.buildName or "Unnamed build", titleW), col.text)
	local parts = { string.format("Level %d %s", self.build.characterLevel or 1, spec.curClassName or "?") }
	if spec.curAscendClassName and spec.curAscendClassName ~= "None" then t_insert(parts, spec.curAscendClassName) end
	if spec.curSecondaryAscendClassName and spec.curSecondaryAscendClassName ~= "None" then t_insert(parts, spec.curSecondaryAscendClassName) end
	local skill = self:MainSkillName()
	if skill then t_insert(parts, "Main skill: " .. skill) end
	Viz.text(x, y + 32, "LEFT", 16, "VAR", Viz.fit(16, "VAR", table.concat(parts, "   |   "), w), col.muted)
	if not chipsInline then
		self:DrawChips(chips, x + m_min(w, chipsW), y + 58)
		return 88
	end
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

-- Inventory (paper doll) ------------------------------------------------------
-- Same arrangement and slot proportions as the in-game inventory, in grid
-- units (one unit = one inventory cell).
local INV_LAYOUT = {
	{ slot = "Weapon 1",    x = 0,    y = 0.6,  w = 2, h = 4, ph = "icon_weapon.png",      swap = "Weapon 1 Swap", phSwap = "icon_weapon_swap.png" },
	{ slot = "Helmet",      x = 3.6,  y = 0.6,  w = 2, h = 2, ph = "icon_helmet.png" },
	{ slot = "Weapon 2",    x = 7.2,  y = 0.6,  w = 2, h = 4, ph = "icon_weapon_2.png",    swap = "Weapon 2 Swap", phSwap = "icon_weapon_2_swap.png" },
	{ slot = "Body Armour", x = 3.6,  y = 2.75, w = 2, h = 3, ph = "icon_body_armour.png" },
	{ slot = "Amulet",      x = 5.85, y = 2.75, w = 1, h = 1, ph = "icon_amulet.png" },
	{ slot = "Ring 1",      x = 2.35, y = 3.85, w = 1, h = 1, ph = "icon_ring_left.png" },
	{ slot = "Ring 2",      x = 5.85, y = 3.85, w = 1, h = 1, ph = "icon_ring_right.png" },
	{ slot = "Gloves",      x = 1.35, y = 5.0,  w = 2, h = 2, ph = "icon_gloves.png" },
	{ slot = "Belt",        x = 3.6,  y = 5.9,  w = 2, h = 1, ph = "icon_belt.png" },
	{ slot = "Boots",       x = 5.85, y = 5.0,  w = 2, h = 2, ph = "icon_boots.png" },
	{ slot = "Flask 1",     x = 2.1,  y = 7.25, w = 1, h = 2, flask = true },
	{ slot = "Flask 2",     x = 3.1,  y = 7.25, w = 1, h = 2, flask = true },
	{ slot = "Flask 3",     x = 4.1,  y = 7.25, w = 1, h = 2, flask = true },
	{ slot = "Flask 4",     x = 5.1,  y = 7.25, w = 1, h = 2, flask = true },
	{ slot = "Flask 5",     x = 6.1,  y = 7.25, w = 1, h = 2, flask = true },
}
local INV_W, INV_H = 9.2, 9.35

local RARITY_COL = {
	UNIQUE = { 0.75, 0.42, 0.16 }, RELIC = { 0.33, 0.78, 0.36 }, RARE = { 0.86, 0.80, 0.36 },
	MAGIC = { 0.46, 0.52, 0.96 }, NORMAL = { 0.62, 0.62, 0.62 },
}
local SLOT_BG = { 0.035, 0.045, 0.115 }

local placeholders = { }
local function placeholder(file)
	if not file then return nil end
	if not placeholders[file] then
		local h = NewImageHandle()
		h:Load("Assets/" .. file)
		placeholders[file] = h
	end
	return placeholders[file]
end

local function drawFitted(handle, x, y, w, h, alpha)
	if not handle or not handle:IsValid() then return false end
	local iw, ih = handle:ImageSize()
	if not iw or iw <= 0 or not ih or ih <= 0 then return false end
	local scale = m_min(w / iw, h / ih, 1.6)
	local dw, dh = iw * scale, ih * scale
	SetDrawColor(1, 1, 1, alpha or 1)
	DrawImage(handle, x + (w - dw) / 2, y + (h - dh) / 2, dw, dh)
	return true
end

-- Simple flask silhouette, used when no picture exists for a flask base.
local function drawFlask(x, y, w, h, c, alpha)
	local cx = x + w / 2
	local neckW, bodyW = w * 0.26, w * 0.62
	local a = alpha or 1
	Viz.rect(cx - neckW / 2 - 2, y + h * 0.12, neckW + 4, h * 0.06, col.physical, a)
	Viz.rect(cx - neckW / 2, y + h * 0.18, neckW, h * 0.2, Viz.mix(c, col.text, 0.35), a * 0.8)
	Viz.arc(cx, y + h * 0.62, 0, bodyW / 2, 0, m_pi * 2, Viz.mix(c, col.text, 0.35), a * 0.8)
	Viz.arc(cx, y + h * 0.62, 0, bodyW / 2 - 2, m_pi * 0.55, m_pi * 1.45, c, a)
end

local function flaskColour(item)
	local n = (item.baseName or "") .. " " .. (item.title or "")
	if n:match("Hybrid") then return col.chaos end
	if n:match("Life") then return col.life end
	if n:match("Mana") then return col.mana end
	return col.dex
end

function OverviewTabClass:InventoryHeight(w)
	local u = m_max(26, m_min(54, (w - 24) / INV_W))
	return m_floor(u * INV_H) + 64
end

function OverviewTabClass:CardInventory(x, y, w, h, o)
	local itemsTab = self.build.itemsTab
	local status = Icons:Status()
	local note = status == "loading" and "fetching icons..." or (status == "failed" and "icons unavailable" or "hover for item, click for Items")
	local cx, cy, cw, ch = self:Card("cInv", x, y, w, h, "Inventory", note, nil, nil)
	local u = m_max(26, m_min(54, cw / INV_W))
	local ox = cx + (cw - u * INV_W) / 2
	local oy = cy
	local set = itemsTab and itemsTab.activeItemSet
	local calcSet = (set and set.useSecondWeaponSet) and 2 or 1
	self.invSet = self.invSet or calcSet

	for _, s in ipairs(INV_LAYOUT) do
		local sx, sy, sw, sh = ox + s.x * u, oy + s.y * u, s.w * u - 4, s.h * u - 4
		local slotName = (s.swap and self.invSet == 2) and s.swap or s.slot
		local slot = itemsTab and itemsTab.slots[slotName]
		local item = slot and slot.selItemId and slot.selItemId > 0 and itemsTab.items[slot.selItemId] or nil
		local id = "inv" .. s.slot
		local hot = self:IsHot(id)
		local inactiveFlask = s.flask and item and slot and slot.active == false

		-- Weapon set tabs above both weapon slots
		if s.swap then
			for n = 1, 2 do
				local tw = 22
				local tx, ty = sx + (n - 1) * (tw + 3), oy
				local tabId = "invTab" .. s.slot .. n
				local on = self.invSet == n
				Viz.softRect(tx, ty, tw, 16, on and col.cardHi or SLOT_BG)
				Viz.outline(tx, ty, tw, 16, on and col.warn or (self:IsHot(tabId) and col.text or col.border))
				Viz.text(tx + tw / 2, ty + 1, "CENTER", 13, "VAR BOLD", n == 1 and "I" or "II", on and col.warn or col.muted)
				self:Hot(tabId, tx, ty, tw, 16, {
					"^7Show weapon set " .. (n == 1 and "I" or "II"),
					"^8Calculations use set " .. (calcSet == 1 and "I" or "II") .. " (change it on the Items tab)",
				}, function() self.invSet = n end)
			end
		end

		Viz.softRect(sx, sy, sw, sh, hot and Viz.mix(SLOT_BG, col.cardHi, 0.6) or SLOT_BG)
		local border = item and (RARITY_COL[item.rarity] or col.border) or col.border
		Viz.outline(sx, sy, sw, sh, hot and col.text or border, item and 0.9 or 0.6)
		if item then Viz.outline(sx + 1, sy + 1, sw - 2, sh - 2, border, 0.35) end

		local pad = 4
		if item then
			local drawn = drawFitted(Icons:Get(item), sx + pad, sy + pad, sw - pad * 2, sh - pad * 2, inactiveFlask and 0.35 or 1)
			if not drawn then
				if s.flask then
					drawFlask(sx, sy, sw, sh, flaskColour(item), inactiveFlask and 0.35 or 1)
				else
					drawFitted(placeholder(s.ph), sx + pad, sy + pad, sw - pad * 2, sh - pad * 2, 0.5)
					local name = item.title or item.baseName or ""
					Viz.text(sx + sw / 2, sy + sh - 16, "CENTER", 11, "VAR", Viz.fit(11, "VAR", name, sw - 6), border)
				end
			end
		else
			if s.flask then
				drawFlask(sx, sy, sw, sh, col.track, 0.6)
			else
				drawFitted(placeholder((s.swap and self.invSet == 2) and s.phSwap or s.ph), sx + pad, sy + pad, sw - pad * 2, sh - pad * 2, 0.22)
			end
		end
		if inactiveFlask then
			Viz.text(sx + sw / 2, sy + sh - 15, "CENTER", 11, "VAR", "off", col.muted)
		end

		self:Hot(id, sx, sy, sw, sh, function(tt)
			if item then
				itemsTab:AddItemTooltip(tt, item, slot)
				if inactiveFlask then
					tt:AddSeparator(10)
					tt:AddLine(14, "^8This flask is not active in calculations (Items tab checkbox)")
				end
			else
				tt:AddLine(16, "^7" .. slotName .. ": ^xF55454empty")
				tt:AddLine(14, "^8Click to open the Items tab")
			end
		end, "ITEMS")
	end
	if status == "failed" then
		Viz.text(cx, cy + ch - 14, "LEFT", 12, "VAR", Viz.fit(12, "VAR", "Item pictures need internet the first time (poe.ninja + GGG image server).", cw), col.muted)
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

-- Advisor (upgrade suggestions pushed by the AI via plan_upgrades) ----------------
local ADVISOR_ROW = 40

function OverviewTabClass:AdvisorHeight()
	local adv = main.agentAdvisor
	if not adv or not adv.items or #adv.items == 0 then return 118 end
	return 64 + m_min(#adv.items, 8) * ADVISOR_ROW
end

local function signed(v, dec)
	return string.format("%+." .. (dec or 1) .. "f", v or 0)
end

function OverviewTabClass:CardAdvisor(x, y, w, h, o)
	local adv = main.agentAdvisor
	local note
	if adv then
		note = string.format("%s  |  <= %dc  |  %s", adv.league or "?", m_floor((adv.budget or 0) + 0.5), adv.focus or "balanced")
		if adv.buildName and adv.buildName ~= self.build.buildName then note = "for " .. adv.buildName end
	end
	local cx, cy, cw, ch = self:Card("cAdv", x, y, w, h, "AI Advisor - cheap upgrades", note, nil, nil)
	if not adv or not adv.items or #adv.items == 0 then
		Viz.text(cx, cy + 2, "LEFT", 15, "VAR", "Ask your AI for upgrades, for example:", col.muted)
		Viz.text(cx, cy + 24, "LEFT", 15, "VAR", Viz.fit(15, "VAR", "\"Find cheap instant-buyout upgrades for this build, 30c each\"", cw), col.text)
		Viz.text(cx, cy + 48, "LEFT", 13, "VAR", Viz.fit(13, "VAR", "Results show up here: hover to compare, click to open the trade listing.", cw), col.muted)
		return
	end
	local itemsTab = self.build.itemsTab
	for i, it in ipairs(adv.items) do
		if i > 8 then break end
		local ry = cy + (i - 1) * ADVISOR_ROW
		local id = "adv" .. i
		local hot = self:IsHot(id)
		Viz.softRect(cx - 4, ry, cw + 8, ADVISOR_ROW - 4, hot and col.cardHi or col.bg, hot and 1 or 0.6)
		-- rank + slot
		Viz.text(cx + 2, ry + 3, "LEFT", 14, "VAR BOLD", tostring(i), col.accent)
		Viz.text(cx + 22, ry + 3, "LEFT", 12, "VAR", (it.slot or ""):upper(), col.muted)
		-- name
		local nameCol = (it.rarity and colorCodes[it.rarity]) or "^7"
		local priceStr = string.format("%s", it.priceText or "")
		local priceW = DrawStringWidth(14, "VAR BOLD", priceStr) + 6
		Viz.text(cx + 22, ry + 18, "LEFT", 14, "VAR", nameCol .. Viz.fit(14, "VAR", it.name or "?", cw * 0.55))
		Viz.text(cx + cw, ry + 3, "RIGHT", 14, "VAR BOLD", priceStr, col.warn)
		-- effect chips
		local chips = { }
		if math.abs(it.dpsPct or 0) >= 0.05 then t_insert(chips, { "DPS " .. signed(it.dpsPct) .. "%", (it.dpsPct or 0) >= 0 and col.accent or col.bad }) end
		if math.abs(it.ehpPct or 0) >= 0.05 then t_insert(chips, { "EHP " .. signed(it.ehpPct) .. "%", (it.ehpPct or 0) >= 0 and col.good or col.bad }) end
		if math.abs(it.lifeDelta or 0) >= 1 then t_insert(chips, { "Life " .. signed(it.lifeDelta, 0), (it.lifeDelta or 0) >= 0 and col.life or col.bad }) end
		if it.resNotes and #it.resNotes > 0 then t_insert(chips, { "res fix", col.cold }) end
		if it.warnings and #it.warnings > 0 then t_insert(chips, { "!", col.bad }) end
		local chipX = cx + cw
		for k = #chips, 1, -1 do
			local label, c = chips[k][1], chips[k][2]
			local cwid = DrawStringWidth(12, "VAR BOLD", label) + 10
			chipX = chipX - cwid
			if chipX < cx + cw * 0.5 then break end
			Viz.softRect(chipX, ry + 19, cwid, 15, Viz.mix(col.card, c, 0.25))
			Viz.text(chipX + 5, ry + 20, "LEFT", 12, "VAR BOLD", label, c)
			chipX = chipX - 4
		end
		self:Hot(id, cx - 4, ry, cw + 8, ADVISOR_ROW - 4, function(tt)
			local okItem, item = pcall(new, "Item", it.itemText or "")
			if okItem and item and item.base and itemsTab then
				itemsTab:AddItemTooltip(tt, item, nil, true)
				tt:AddSeparator(10)
			else
				tt:AddLine(16, "^7" .. (it.name or "?"))
			end
			tt:AddLine(15, string.format("^7In your build (%s): ^x4FD1C2DPS %s%%  ^x5CD677EHP %s%%  ^xE04854Life %s", it.slot or "?", signed(it.dpsPct), signed(it.ehpPct), signed(it.lifeDelta, 0)))
			for _, n in ipairs(it.resNotes or { }) do tt:AddLine(14, "^x6C8FD9" .. n) end
			for _, wn in ipairs(it.warnings or { }) do tt:AddLine(14, "^xF55454Warning: " .. wn) end
			tt:AddLine(14, string.format("^7Price: ^xF5A742%s ^8(~%dc)%s", it.priceText or "?", m_floor((it.priceChaos or 0) + 0.5), it.seller and ("  seller " .. it.seller) or ""))
			tt:AddLine(13, "^x4FD1C2Click to open this listing on pathofexile.com (buy it with instant buyout)")
		end, function()
			if it.url and it.url:match("^https://www%.pathofexile%.com/trade/") then OpenURL(it.url) end
		end)
	end
end

-- Atlas (summary of the build's atlas tree) ----------------------------------------
function OverviewTabClass:CardAtlas(x, y, w, h, o)
	local tab = self.build.atlasTab
	local atlas = tab and tab:Data()
	local cx, cy, cw, ch = self:Card("cAtlas", x, y, w, h, "Atlas Tree", atlas and ("version " .. atlas.version:gsub("_", ".")) or nil, nil, "ATLAS")
	if not atlas then
		Viz.text(cx, cy, "LEFT", 14, "VAR", "Atlas data not available", col.muted)
		return
	end
	local s = LoadModule("Agent/AtlasData").summary(atlas, tab.alloc)
	Viz.text(cx, cy, "LEFT", 14, "VAR", string.format("%d / %d points", s.used, atlas.points), col.text)
	Viz.bar(cx + 110, cy + 5, cw - 110, 7, s.used / atlas.points, { 0.86, 0.68, 0.32 })
	cy = cy + 22
	if s.used == 0 then
		Viz.text(cx, cy, "LEFT", 13, "VAR", "No atlas passives yet. Open the Atlas tab,", col.muted)
		Viz.text(cx, cy + 16, "LEFT", 13, "VAR", "import a guide's link, or ask your AI to plan one.", col.muted)
		return
	end
	local maxPts = s.mechanics[1] and s.mechanics[1].points or 1
	for i, m in ipairs(s.mechanics) do
		if i > 4 then break end
		Viz.text(cx, cy, "LEFT", 13, "VAR", Viz.fit(13, "VAR", m.name, cw * 0.55), col.text)
		Viz.text(cx + cw, cy, "RIGHT", 13, "VAR BOLD", tostring(m.points), col.muted)
		Viz.bar(cx, cy + 16, cw, 4, m.points / maxPts, col.accent)
		self:Hot("atl" .. i, cx, cy, cw, 24, function(tt)
			tt:AddLine(16, "^7" .. m.name .. ": " .. m.points .. " points")
			for _, n in ipairs(m.notables) do tt:AddLine(14, "^xD9B45A" .. n.name) end
		end, "ATLAS")
		cy = cy + 24
	end
	local keystones = { }
	for _, n in ipairs(s.special) do if n.type == "keystone" then table.insert(keystones, n.name) end end
	if #keystones > 0 then
		Viz.text(cx, cy + 2, "LEFT", 13, "VAR", "^xE8C35A" .. Viz.fit(13, "VAR", "Keystones: " .. table.concat(keystones, ", "), cw))
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

	local bannerH = self:DrawUpdateBanner(x, y, w)
	if bannerH > 0 then y = y + bannerH + 10 end
	y = y + self:DrawHeader(x, y, w, o) + 10
	y = y + self:DrawTiles(x, y, w, o) + 14

	local cols = viewPort.width >= 1150 and 3 or (viewPort.width >= 700 and 2 or 1)
	local gap = 14
	local cardW = (w - gap * (cols - 1)) / cols
	local cards = {
		{ fn = self.CardAdvisor, h = self:AdvisorHeight() },
		{ fn = self.CardInventory, h = self:InventoryHeight(cardW) },
		{ fn = self.CardDamageTypes, h = 196 },
		{ fn = self.CardDamageSources, h = 196 },
		{ fn = self.CardOffense, h = 196 },
		{ fn = self.CardResists, h = 196 },
		{ fn = self.CardMaxHit, h = 196 },
		{ fn = self.CardAvoidance, h = 196 },
		{ fn = self.CardSkills, h = 210 },
		{ fn = self.CardAilments, h = 210 },
		{ fn = self.CardResources, h = 196 },
		{ fn = self.CardHealth, h = 196 },
		{ fn = self.CardAtlas, h = 196 },
		{ fn = self.CardAttributes, h = 196 },
	}
	local colY = { }
	for c = 1, cols do colY[c] = y end
	for _, card in ipairs(cards) do
		local c = 1
		for k = 2, cols do if colY[k] < colY[c] - 1 then c = k end end
		local cx = x + (c - 1) * (cardW + gap)
		local ok, err = pcall(card.fn, self, cx, colY[c], cardW, card.h, o)
		if not ok then
			Viz.text(cx + 12, colY[c] + 40, "LEFT", 14, "VAR", "Error: " .. tostring(err), col.bad)
		end
		colY[c] = colY[c] + card.h + gap
	end
	local bottom = math.max(unpack(colY)) - gap + pad
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
