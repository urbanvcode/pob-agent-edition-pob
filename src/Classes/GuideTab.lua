-- Path of Building - Agent Edition
--
-- Class: Guide Tab
-- Follow a build guide stage by stage, without an AI app:
--   * pick a guide ("Guide - <name>" builds) and a stage (its loadouts), or import one from a link/code;
--   * Analyse: PoB simulates every gap in your build (Agent/Handlers/Guide.lua) and ranks
--     the next steps by what your character lacks most (resists, defence or damage);
--   * your tree with the guide's stage drawn over it (green = take, red = not in the guide)
--     and the next passives numbered 1, 2, 3 in the order to take them;
--   * Sync character (and optional auto-sync) from pathofexile.com (Agent/CharacterSync.lua).
-- Results are shared with the AI tools (AgentCache/guide/state.json and card.json).
--
local Viz = LoadModule("Agent/Viz")
-- One sync state for the whole window (Build.lua ticks it every frame).
main.agentSync = main.agentSync or LoadModule("Agent/CharacterSync")
local Sync = main.agentSync
local AgentSettings = LoadModule("Agent/Settings")
local dkjson = require("dkjson")
local col = Viz.col
local m_max, m_min, m_floor = math.max, math.min, math.floor
local t_insert = table.insert

local PANEL_W = 460
local KIND_LABEL = { gem = "GEM", ["gem levels"] = "LEVELS", ["skill group"] = "GROUP", item = "ITEM", jewel = "JEWEL" }
local TOOLBAR_H = 56

local GuideTabClass = newClass("GuideTab", "ControlHost", "Control", function(self, build)
	self.ControlHost()
	self.Control()
	self.build = build
	self.scrollY = 0
	self.contentHeight = 0
	self.hot, self.lastHot = { }, { }
	self.tooltip = new("Tooltip")
	self.guides = { }
	self.entries = { }      -- loaded guide builds (CompareEntry) by file
	self.message = nil

	self.controls.guideLabel = new("LabelControl", { "TOPLEFT", self, "TOPLEFT" }, { 8, 8, 0, 16 }, "^7Guide:")
	self.controls.guideSelect = new("DropDownControl", { "LEFT", self.controls.guideLabel, "RIGHT" }, { 4, 0, 300, 20 }, { }, function(index)
		self:SelectGuide(index)
	end)
	self.controls.import = new("ButtonControl", { "LEFT", self.controls.guideSelect, "RIGHT" }, { 6, 0, 110, 20 }, "Import guide...", function()
		self:OpenImportPopup()
	end)
	self.controls.stageLabel = new("LabelControl", { "LEFT", self.controls.import, "RIGHT" }, { 14, 0, 0, 16 }, "^7Stage:")
	self.controls.stageSelect = new("DropDownControl", { "LEFT", self.controls.stageLabel, "RIGHT" }, { 4, 0, 250, 20 }, { }, function(index)
		self:SelectStage(index)
	end)
	self.controls.analyse = new("ButtonControl", { "LEFT", self.controls.stageSelect, "RIGHT" }, { 6, 0, 90, 20 }, "Analyse", function()
		self:RequestAnalysis()
	end)
	self.controls.analyse.tooltipText = "PoB simulates every difference between your build and the guide stage (10-20 s; your build is put back exactly)."
	self.controls.sync = new("ButtonControl", { "TOPLEFT", self, "TOPLEFT" }, { 8, 32, 130, 20 }, "Sync character", function()
		Sync.start(self.build, false)
	end)
	self.controls.sync.tooltipFunc = function(tooltip)
		tooltip:Clear()
		local ok, info = Sync.check(self.build)
		tooltip:AddLine(14, ok and ("^7Re-import " .. info.character .. " from your public pathofexile.com profile (3 requests).") or ("^7" .. tostring(info)))
		tooltip:AddLine(13, "^8Read-only, no login. At most once a minute.")
	end
	self.controls.sync.enabled = function() return not Sync.busy end
	self.controls.autoSync = new("CheckBoxControl", { "LEFT", self.controls.sync, "RIGHT" }, { 150, 0, 18 }, "Auto every 15 min:", function(state)
		Sync.setAuto(state)
	end, "While PoB is open and your synced character's build is open (and saved), re-sync it every 15 minutes. Off by default.")
	self.controls.autoSync.state = Sync.autoEnabled()
end)

-- Shared state with the AI tools ---------------------------------------------------------
local function guideDir() return (main.userPath or "") .. "AgentCache/guide/" end

local function readJson(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	local ok, data = pcall(dkjson.decode, text)
	return ok and type(data) == "table" and data or nil
end

local function writeJson(path, value)
	MakeDir(guideDir())
	local f = io.open(path .. ".tmp", "w")
	if not f then return end
	f:write(dkjson.encode(value))
	f:close()
	os.remove(path)
	os.rename(path .. ".tmp", path)
end

function GuideTabClass:State()
	local state = readJson(guideDir() .. "state.json") or { }
	state.builds = state.builds or { }
	return state
end

function GuideTabClass:Choice()
	local state = self:State()
	return state.builds[self.build.buildName] or { accept = { } }, state
end

function GuideTabClass:SaveChoice(choice)
	local state = self:State()
	choice.accept = choice.accept or { }
	state.builds[self.build.buildName] = choice
	state.last = choice.guide
	writeJson(guideDir() .. "state.json", state)
end

local function handlers()
	local server = launch.agentServer
	return server and server.handlers
end

-- Guides on disk ---------------------------------------------------------------------------
function GuideTabClass:ScanGuides()
	local list = { }
	local handle = NewFileSearch(main.buildPath .. "Guide - *.xml")
	while handle do
		local file = handle:GetFileName()
		t_insert(list, { name = file:gsub("%.xml$", ""), file = main.buildPath .. file, mtime = handle:GetFileModifiedTime() })
		if not handle:NextFile() then break end
	end
	table.sort(list, function(a, b) return a.mtime > b.mtime end)
	self.guides = list
	local names = { }
	for _, g in ipairs(list) do t_insert(names, g.name) end
	if #names == 0 then names = { "(no guide yet: Import guide...)" } end
	self.controls.guideSelect.list = names
	-- Pick the remembered guide for this build.
	local choice, state = self:Choice()
	local want = choice.guide or state.last
	local index = 1
	for i, g in ipairs(list) do if g.name == want then index = i end end
	self.controls.guideSelect.selIndex = index
	self.scannedAt = GetTime()
end

function GuideTabClass:Guide()
	return self.guides[self.controls.guideSelect.selIndex or 1]
end

-- Loads the guide as a second build PoB calculates on its own (like the Compare tab).
function GuideTabClass:Entry(guide)
	if not guide then return nil end
	local cached = self.entries[guide.file]
	if cached and cached.mtime == guide.mtime then return cached.entry, cached.stages end
	local f = io.open(guide.file, "r")
	if not f then return nil end
	local xml = f:read("*a")
	f:close()
	local ok, entry = pcall(new, "CompareEntry", xml, guide.name)
	if not ok or not entry or not entry.treeTab then
		self.message = "Could not load " .. guide.name .. ": " .. tostring(entry)
		return nil
	end
	local h = handlers()
	local stages = h and h._withBuild(entry, h.guide_stages, { all = true })
	self.entries[guide.file] = { entry = entry, stages = stages and stages.stages or { }, mtime = guide.mtime }
	return entry, self.entries[guide.file].stages
end

function GuideTabClass:SelectGuide(index)
	local guide = self.guides[index]
	if not guide then return end
	local choice = self:Choice()
	if choice.guide ~= guide.name then
		choice = { guide = guide.name, accept = { } }
		self:SaveChoice(choice)
	end
	self.result = nil
	self:RefreshStages()
end

function GuideTabClass:RefreshStages()
	local guide = self:Guide()
	local entry, stages = self:Entry(guide)
	self.stages = stages or { }
	local list = { }
	local h = handlers()
	self.detected = nil
	if h and #self.stages > 0 then
		local me = h.guide_stages({ })
		local det = me.ok and h.guide_detect({ stages = self.stages, me = me.stages[1], level = me.level, pointsAtLevel = me.pointsAtLevel })
		if det and det.ok then self.detected = det end
	end
	local detTitle = "?"
	for _, s in ipairs(self.stages) do if self.detected and s.index == self.detected.index then detTitle = s.title end end
	t_insert(list, "Auto (closest: " .. detTitle .. ")")
	for _, s in ipairs(self.stages) do t_insert(list, s.index .. ". " .. s.title .. (s.levelling and "  [levelling]" or "")) end
	self.controls.stageSelect.list = list
	local choice = self:Choice()
	local sel = 1
	for i, s in ipairs(self.stages) do if choice.stage and s.title == choice.stage then sel = i + 1 end end
	self.controls.stageSelect.selIndex = sel
end

function GuideTabClass:SelectStage(index)
	local choice = self:Choice()
	choice.guide = choice.guide or (self:Guide() and self:Guide().name)
	choice.stage = index > 1 and self.stages[index - 1] and self.stages[index - 1].title or nil
	self:SaveChoice(choice)
	self.result = nil
end

function GuideTabClass:CurrentStage()
	local sel = self.controls.stageSelect.selIndex or 1
	if sel > 1 then return self.stages[sel - 1], "chosen" end
	for _, s in ipairs(self.stages or { }) do
		if self.detected and s.index == self.detected.index then return s, "detected" end
	end
	return self.stages and self.stages[1], "detected"
end

-- Analysis -----------------------------------------------------------------------------------
local function signature(build)
	local o = build.calcsTab.mainOutput or { }
	return tostring(build.spec:CountAllocNodes()) .. "|" .. tostring(o.CombinedDPS) .. "|" .. tostring(o.TotalEHP) .. "|" .. tostring(build.characterLevel)
end

function GuideTabClass:RequestAnalysis()
	if not self.scannedAt then
		self:ScanGuides()
		self:RefreshStages()
	end
	if not self:Guide() then self.message = "Import a guide first." return end
	self.pending = 2  -- draw the "analysing" frame first, then run
end

function GuideTabClass:Analyse()
	local h = handlers()
	if not h or not h.guide_gap then self.message = "The agent link is not running in this window." return end
	local guide = self:Guide()
	local entry = self:Entry(guide)
	if not entry then return end
	local stage, reason = self:CurrentStage()
	if not stage then self.message = "This guide has no stages." return end
	local data = h._withBuild(entry, h.guide_data, { stage = stage.index })
	if not data or not data.ok then self.message = "Could not read the guide stage: " .. tostring(data and data.error) return end
	local profile = AgentSettings.getProfile(main.userPath) or { }
	local choice = self:Choice()
	local res = h.guide_gap({ guide = data, skip = choice.accept or { }, levelling = stage.levelling == true, hardcore = profile.hardcore == true,
		league = profile.league ~= "" and profile.league or nil, playMode = profile.playMode })
	if not res or not res.ok then self.message = "Analysis failed: " .. tostring(res and res.error) return end
	self.result, self.guideData, self.stage, self.stageReason = res, data, stage, reason
	self.signature = signature(self.build)
	self.message = nil
	self.focusEntry = entry
	self:WriteCard()
end

local function dpsOf(s)
	if not s then return 0 end
	if (s.FullDPS or 0) > 0 then return s.FullDPS end
	return s.CombinedDPS or s.TotalDPS or 0
end

function GuideTabClass:WriteCard()
	local r, g = self.result, self.guideData
	local next = { }
	local plan = r.plan or { }
	local function add(x, view)
		if #next < 3 and x then
			t_insert(next, { text = x.text, kind = x.kind, view = view or x.view, dpsPct = x.gain and x.gain.dpsPct, ehpPct = x.gain and x.gain.ehpPct, link = x.link })
		end
	end
	-- The card shows the best value per point, not the first prerequisite on the path.
	local best = { }
	for _, p in ipairs(plan.passives or { }) do t_insert(best, p) end
	table.sort(best, function(a, b) return (a.gain.score or 0) / m_max(1, a.points or 1) > (b.gain.score or 0) / m_max(1, b.points or 1) end)
	add(best[1], "TREE")
	add(plan.other and plan.other[1])
	add(best[2], "TREE")
	add(plan.other and plan.other[2])
	local detTitle
	for _, s in ipairs(self.stages) do if self.detected and s.index == self.detected.index then detTitle = s.title end end
	writeJson(guideDir() .. "card.json", {
		build = self.build.buildName, guide = self:Guide().name, stage = self.stage.title, stageIndex = self.stage.index,
		stages = #self.stages, reason = self.stageReason, detected = detTitle, at = os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
		match = { passives = { r.tree.have or 0, r.tree.total or 0 }, gems = { r.gems.have or 0, r.gems.total or 0 }, items = { r.items.have or 0, r.items.total or 0 } },
		dps = { dpsOf(r.stats), dpsOf(g.stats) }, ehp = { r.stats.TotalEHP or 0, g.stats.TotalEHP or 0 },
		focus = r.focus and r.focus.title, levelling = r.levelling == true,
		rush = plan.rush and { target = plan.rush.target, points = plan.rush.points, dpsPct = plan.rush.dpsPct, ehpPct = plan.rush.ehpPct } or nil,
		next = next,
	})
end

function GuideTabClass:Accept(name)
	local choice = self:Choice()
	choice.guide = choice.guide or (self:Guide() and self:Guide().name)
	choice.accept = choice.accept or { }
	t_insert(choice.accept, name)
	self:SaveChoice(choice)
	self:RequestAnalysis()
end

-- Import ----------------------------------------------------------------------------------------
local function decodeCode(text)
	text = text:gsub("%s+", "")
	if text:sub(1, 1) == "<" then return text end
	local ok, xml = pcall(function() return Inflate(common.base64.decode(text:gsub("-", "+"):gsub("_", "/"))) end)
	return ok and xml or nil
end

function GuideTabClass:SaveGuide(xml, source, name)
	if not xml or not xml:find("<PathOfBuilding") then self.message = "That is not a PoB build code." return end
	local note = "Guide imported by PoB Agent Edition on " .. os.date("!%Y-%m-%d") .. " from: " .. source
	if xml:find("<Notes/>") then xml = xml:gsub("<Notes/>", function() return "<Notes>" .. note .. "</Notes>" end, 1)
	elseif xml:find("<Notes>") then xml = xml:gsub("<Notes>", function() return "<Notes>" .. note .. "\n\n" end, 1)
	else xml = xml:gsub("</PathOfBuilding>", function() return "<Notes>" .. note .. "</Notes>\n</PathOfBuilding>" end, 1) end
	local base = (name or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub('[<>:"/\\|%?%*]', "")
	if base == "" then
		local ok, entry = pcall(new, "CompareEntry", xml, "Guide")
		local h = handlers()
		local ks = ok and h and h._withBuild(entry, h.key_stats, { })
		base = ((ks and ks.ascendancy ~= "None" and ks.ascendancy) or (ks and ks.className) or "Build") .. " " .. tostring(ks and ks.mainSkill or "")
		base = base:gsub("%s+$", "")
	end
	local fileName = "Guide - " .. base
	local k = 2
	while io.open(main.buildPath .. fileName .. ".xml", "r") do
		fileName = "Guide - " .. base .. " (" .. k .. ")"
		k = k + 1
	end
	local f = io.open(main.buildPath .. fileName .. ".xml", "w")
	if not f then self.message = "Could not write " .. fileName .. ".xml" return end
	f:write(xml)
	f:close()
	self:ScanGuides()
	for i, g in ipairs(self.guides) do if g.name == fileName then self.controls.guideSelect.selIndex = i end end
	self:SelectGuide(self.controls.guideSelect.selIndex)
	self.message = "Saved \"" .. fileName .. "\". Pick a stage (or keep Auto) and press Analyse."
end

function GuideTabClass:OpenImportPopup()
	local controls = { }
	controls.label = new("LabelControl", nil, { 0, 20, 0, 16 }, "^7Paste the guide's PoB link (pobb.in, poe.ninja, pastebin, maxroll...) or PoB code:")
	controls.edit = new("EditControl", nil, { 0, 42, 560, 20 }, "", nil, "^%c", nil)
	controls.nameLabel = new("LabelControl", nil, { -150, 70, 0, 16 }, "^7Name (optional):")
	controls.name = new("EditControl", nil, { 60, 70, 300, 20 }, "", nil, '[<>:"/\\|%?%*]', 60)
	controls.note = new("LabelControl", nil, { 0, 96, 0, 14 }, "^8Saved as a new \"Guide - <name>\" build; your build is not touched. Mobalytics: use the guide's PoB link.")
	controls.go = new("ButtonControl", nil, { -50, 122, 90, 20 }, "Import", function()
		local text = controls.edit.buf:gsub("^%s+", ""):gsub("%s+$", "")
		local name = controls.name.buf
		main:ClosePopup()
		if text:match("mobalytics%.gg") then
			self.message = "Mobalytics pages are built by JavaScript: open the guide, copy its PoB link or code, and paste that."
			return
		end
		if text:match("^https?://") then
			for _, site in ipairs(buildSites.websiteList) do
				if text:match(site.matchURL) then
					self.message = "Downloading the guide from " .. site.label .. "..."
					buildSites.DownloadBuild(text, site, function(ok, data)
						if not ok then self.message = "Download failed: " .. tostring(data) return end
						self:SaveGuide(decodeCode(data or ""), text, name)
					end)
					return
				end
			end
			self.message = "Unknown build site. Paste the PoB code instead."
			return
		end
		self:SaveGuide(decodeCode(text), "a PoB code", name)
	end)
	controls.cancel = new("ButtonControl", nil, { 50, 122, 90, 20 }, "Cancel", function() main:ClosePopup() end)
	main:OpenPopup(620, 152, "Import a guide", controls, "go", "edit", "cancel")
end

-- Drawing helpers ---------------------------------------------------------------------------------
local function regionAt(list, mx, my)
	for i = #list, 1, -1 do
		local r = list[i]
		if mx >= r.x and mx < r.x + r.w and my >= r.y and my < r.y + r.h then return r end
	end
end

function GuideTabClass:Hot(id, x, y, w, h, tip, click)
	t_insert(self.hot, { id = id, x = x, y = y, w = w, h = h, tip = tip, click = click })
end

local function signed(v) return string.format("%+.1f%%", tonumber(v) or 0) end

local function chips(x, y, gain)
	local list = { }
	if gain then
		if math.abs(gain.dpsPct or 0) >= 0.05 then t_insert(list, { "DPS " .. signed(gain.dpsPct), (gain.dpsPct or 0) >= 0 and col.accent or col.bad }) end
		if math.abs(gain.ehpPct or 0) >= 0.05 then t_insert(list, { "EHP " .. signed(gain.ehpPct), (gain.ehpPct or 0) >= 0 and col.good or col.bad }) end
		for _, k in ipairs({ "fire", "cold", "lightning", "chaos" }) do
			local v = gain.res and gain.res[k] or 0
			if math.abs(v) >= 1 then t_insert(list, { k:sub(1, 1):upper() .. k:sub(2) .. string.format(" %+d", v), v > 0 and col[k] or col.bad }) end
		end
	end
	local cx = x
	for k = #list, 1, -1 do
		local label, c = list[k][1], list[k][2]
		local w = DrawStringWidth(12, "VAR BOLD", label) + 10
		cx = cx - w
		Viz.softRect(cx, y, w, 15, Viz.mix(col.card, c, 0.25))
		Viz.text(cx + 5, y + 1, "LEFT", 12, "VAR BOLD", label, c)
		cx = cx - 4
	end
	return x - cx
end

-- Centres the tree on a node.
function GuideTabClass:FocusNode(id)
	local node = id and self.build.spec.nodes[id]
	if node and self.treeVP then
		self.build.treeTab.viewer:Focus(node.x, node.y, self.treeVP, self.build)
	end
end

-- The panel on the left -------------------------------------------------------------------------
function GuideTabClass:DrawPanel(x, y, w)
	local r = self.result
	local y0 = y
	if self.pending then
		Viz.text(x, y, "LEFT", 16, "VAR BOLD", "Analysing...", col.accent)
		Viz.text(x, y + 22, "LEFT", 13, "VAR", "PoB simulates every difference in your build (10-20 s).", col.muted)
		return 60
	end
	if not r then
		Viz.text(x, y, "LEFT", 15, "VAR BOLD", "Follow a guide, stage by stage", col.text)
		local lines = {
			"1. Import guide... (paste its PoB link or code), or pick one above.",
			"2. Keep Stage on Auto (closest stage) or pick one.",
			"3. Press Analyse: PoB simulates each difference in your build",
			"   and ranks what to do next by what you lack most.",
			"The tree on the right shows the guide's stage over yours:",
			"green = take it, red = not in the guide, numbers = order.",
			"",
			"Your AI app can do the same, plus prices and budgets:",
			"\"what next toward my guide with 2 divines?\"",
		}
		for i, l in ipairs(lines) do Viz.text(x, y + 6 + i * 18, "LEFT", 13, "VAR", l, i <= 4 and col.text or col.muted) end
		return 6 + #lines * 18 + 24
	end
	if self.signature ~= signature(self.build) then
		Viz.softRect(x - 4, y - 2, w + 8, 22, Viz.mix(col.card, col.warn, 0.2))
		Viz.text(x, y + 1, "LEFT", 13, "VAR", "Your build changed since the analysis: press Analyse again.", col.warn)
		y = y + 28
	end
	-- Stage
	local stageText = string.format("Stage %d/%d: %s (%s)", self.stage.index, #self.stages, self.stage.title, self.stageReason)
	Viz.text(x, y, "LEFT", 15, "VAR BOLD", Viz.fit(15, "VAR BOLD", stageText, w - 90), col.text)
	if r.levelling then
		Viz.softRect(x + w - 82, y, 82, 18, Viz.mix(col.card, col.lightning, 0.3))
		Viz.text(x + w - 76, y + 2, "LEFT", 12, "VAR BOLD", "LEVELLING", col.lightning)
	end
	y = y + 24
	-- Focus
	local f = r.focus or { }
	local fc = (f.kind == "damage") and col.fire or ((f.kind == "balanced") and col.accent or col.good)
	Viz.softRect(x - 4, y - 2, w + 8, 20 + 16 * #(f.reasons or { }), Viz.mix(col.card, fc, 0.15))
	Viz.text(x, y, "LEFT", 15, "VAR BOLD", "Focus: " .. tostring(f.title), fc)
	for i, reason in ipairs(f.reasons or { }) do
		Viz.text(x + 8, y + 2 + i * 16, "LEFT", 12, "VAR", Viz.fit(12, "VAR", reason, w - 12), col.muted)
	end
	self:Hot("focus", x - 4, y - 2, w + 8, 20 + 16 * #(f.reasons or { }), {
		"^7What your character lacks most decides the order:",
		"^8- elemental resistances under their cap come first;",
		"^8- otherwise defence or damage, whichever is further behind the guide stage;",
		string.format("^8Gains are weighed DPS x%s, EHP x%s%s.", tostring(f.wDps), tostring(f.wEhp), next(f.resMissing or { }) and ", plus 2 per missing resistance point" or ""),
	})
	y = y + 26 + 16 * #(f.reasons or { })
	-- Matched + vs guide
	local bars = {
		{ "Passives", r.tree.have, r.tree.total, col.accent, "TREE" },
		{ "Gems", r.gems.have, r.gems.total, col.good, "SKILLS" },
		{ "Key items", r.items.have, r.items.total, col.warn, "ITEMS" },
	}
	for _, b in ipairs(bars) do
		local frac = (b[3] or 0) > 0 and (b[2] or 0) / b[3] or 1
		Viz.text(x, y, "LEFT", 13, "VAR", b[1], col.muted)
		Viz.bar(x + 74, y + 5, w - 74 - 90, 7, frac, b[4])
		Viz.text(x + w, y, "RIGHT", 13, "VAR", string.format("%d/%d  %d%%", b[2] or 0, b[3] or 0, m_floor(frac * 100 + 0.5)), col.text)
		y = y + 18
	end
	local gs = self.guideData.stats or { }
	local function vs(label, a, b, xx)
		Viz.text(xx, y, "LEFT", 13, "VAR", label, col.muted)
		Viz.text(xx + 36, y, "LEFT", 13, "VAR BOLD", b > 0 and string.format("%d%%", m_floor(a / b * 100 + 0.5)) or "-", col.text)
		Viz.text(xx + 80, y, "LEFT", 12, "VAR", Viz.num(a) .. " / " .. Viz.num(b), col.muted)
	end
	vs("DPS", dpsOf(r.stats), dpsOf(gs), x)
	vs("EHP", r.stats.TotalEHP or 0, gs.TotalEHP or 0, x + w / 2)
	y = y + 26
	-- Rush
	local plan = r.plan or { }
	if plan.rush then
		local id = "rush"
		local hot = self.hoverId == id
		Viz.softRect(x - 4, y - 2, w + 8, 34, hot and col.cardHi or Viz.mix(col.card, col.lightning, 0.12))
		Viz.text(x, y, "LEFT", 12, "VAR BOLD", "RUSH", col.lightning)
		Viz.text(x + 44, y, "LEFT", 14, "VAR BOLD", Viz.fit(14, "VAR BOLD", plan.rush.target .. " (" .. plan.rush.points .. " points with its path)", w - 44), col.text)
		chips(x + w, y + 16, { dpsPct = plan.rush.dpsPct, ehpPct = plan.rush.ehpPct })
		Viz.text(x + 44, y + 17, "LEFT", 12, "VAR", "best gain per point among far targets", col.muted)
		self:Hot(id, x - 4, y - 2, w + 8, 34, { "^7Rush: the best target 3 or more points away, counting the points of its path.", "^8Click to show it on the tree." }, function() self:FocusNode(self:StepTarget(plan.rush.idx)) end)
		y = y + 42
	end
	-- Next passives
	Viz.text(x, y, "LEFT", 12, "VAR", string.format("NEXT PASSIVES  (%d unspent point%s%s)", plan.free or 0, plan.free == 1 and "" or "s",
		r.levelling and "; levelling: no respec" or ""), col.muted)
	y = y + 18
	if #(plan.passives or { }) == 0 then
		Viz.text(x, y, "LEFT", 13, "VAR", "Nothing on the guide's path adds DPS or EHP now.", col.muted)
		y = y + 20
	end
	for i, p in ipairs(plan.passives or { }) do
		if i > 8 then break end
		local id = "p" .. i
		local hot = self.hoverId == id
		Viz.softRect(x - 4, y - 1, w + 8, 20, hot and col.cardHi or col.bg, hot and 1 or 0.5)
		Viz.text(x, y + 1, "LEFT", 14, "VAR BOLD", tostring(i), col.accent)
		local cw = chips(x + w, y + 2, p.gain)
		Viz.text(x + 20, y + 1, "LEFT", 13, "VAR", Viz.fit(13, "VAR", p.text .. " (" .. p.points .. ")", w - 24 - cw), col.text)
		self:Hot(id, x - 4, y - 1, w + 8, 20, { "^7" .. p.text, string.format("^8%d point%s, %s", p.points, p.points == 1 and "" or "s", tostring(p.kind)), "^8Gain on top of the steps before it (PoB simulation).", "^x4FD1C2Click to show it on the tree" },
			function() self:FocusNode(p.nodes and p.nodes[#p.nodes]) end)
		y = y + 21
	end
	y = y + 8
	-- Gems and gear
	Viz.text(x, y, "LEFT", 12, "VAR", "GEMS AND GEAR", col.muted)
	y = y + 18
	if #(plan.other or { }) == 0 then
		Viz.text(x, y, "LEFT", 13, "VAR", "Nothing from the guide's gems or gear adds DPS or EHP now.", col.muted)
		y = y + 20
	end
	for i, o in ipairs(plan.other or { }) do
		if i > 8 then break end
		local id = "o" .. i
		local hot = self.hoverId == id
		Viz.softRect(x - 4, y - 1, w + 8, 20, hot and col.cardHi or col.bg, hot and 1 or 0.5)
		Viz.text(x, y + 3, "LEFT", 10, "VAR", KIND_LABEL[o.kind] or (o.kind or ""):upper(), col.muted)
		local cw = chips(x + w - 40, y + 2, o.gain)
		Viz.text(x + 58, y + 1, "LEFT", 13, "VAR", Viz.fit(13, "VAR", o.text, w - 104 - cw), o.unique and colorCodes.UNIQUE and col.warn or col.text)
		self:Hot(id, x - 4, y - 1, w - 30, 20, {
			"^7" .. o.text, "^8Simulated alone in your build (PoB).",
			o.link and "^x4FD1C2Click to open the instant-buyout search on pathofexile.com" or ("^x4FD1C2Click to open the " .. tostring(o.view):lower() .. " tab"),
		}, function()
			if o.link and o.link:match("^https://www%.pathofexile%.com/trade/") then OpenURL(o.link) else self.build.viewMode = o.view end
		end)
		local keep = o.name or o.slot
		if keep then
			local kid = "k" .. i
			local khot = self.hoverId == kid
			Viz.text(x + w, y + 3, "RIGHT", 11, "VAR", "keep", khot and col.accent or col.muted)
			self:Hot(kid, x + w - 30, y - 1, 34, 20, { "^7Keep my choice: stop flagging " .. tostring(keep) .. " (remembered for this build)." }, function() self:Accept(keep) end)
		end
		y = y + 21
	end
	-- Levelling notes
	if r.levelling then
		y = y + 8
		Viz.text(x, y, "LEFT", 12, "VAR", "LEVELLING", col.muted)
		y = y + 18
		local notes = { "Act 5 and Act 10 each lower your resistances by 30%: cap them again after each." }
		local nextStage
		for _, s in ipairs(self.stages) do if s.index == self.stage.index + 1 then nextStage = s end end
		if nextStage then
			local now = { }
			for _, sk in ipairs(self.stage.skills or { }) do now[sk.name:lower()] = true end
			local fresh = { }
			for _, sk in ipairs(nextStage.skills or { }) do
				if not now[sk.name:lower()] then t_insert(fresh, sk.name .. (sk.req and (" (level " .. sk.req .. ")") or "")) end
			end
			if #fresh > 0 then t_insert(notes, "Next stage \"" .. nextStage.title .. "\" uses " .. table.concat(fresh, ", ") .. ".") end
		end
		local later = { }
		for _, g in ipairs(r.gems.groups or { }) do
			for _, m in ipairs(g.missing or { }) do if m.later then t_insert(later, m.name .. " (" .. m.later .. ")") end end
			if g.absent and g.later then t_insert(later, tostring(g.skill) .. " group (" .. g.later .. ")") end
		end
		if #later > 0 then t_insert(notes, "Gems for later levels: " .. table.concat(later, ", ") .. ".") end
		for _, n in ipairs(notes) do
			local lines = Viz.wrap and Viz.wrap(13, "VAR", n, w) or { n }
			for _, l in ipairs(lines) do
				Viz.text(x, y, "LEFT", 13, "VAR", Viz.fit(13, "VAR", l, w), col.text)
				y = y + 17
			end
		end
	end
	y = y + 10
	Viz.text(x, y, "LEFT", 12, "VAR", "Prices and budgets: ask your AI \"what next toward my guide with 2 div?\"", col.muted)
	y = y + 18
	return y - y0
end

function GuideTabClass:StepTarget(idx)
	local step = self.result and self.result.tree.steps and self.result.tree.steps[idx]
	return step and step.nodes and step.nodes[#step.nodes] or nil
end

-- Numbers on the tree: the next passives in the order to take them.
function GuideTabClass:DrawPathNumbers(vp)
	local plan = self.result and self.result.plan
	if not plan or not plan.passives then return end
	local viewer = self.build.treeTab.viewer
	local tree = self.build.spec.tree
	local scale = m_min(vp.width, vp.height) / tree.size * viewer.zoom
	local ox, oy = viewer.zoomX + vp.x + vp.width / 2, viewer.zoomY + vp.y + vp.height / 2
	local function badge(node, text, c, size)
		if not node or not node.x then return end
		local sx, sy = node.x * scale + ox, node.y * scale + oy
		local w = DrawStringWidth(size, "VAR BOLD", text) + 8
		Viz.rect(sx - w / 2, sy - size / 2 - 3, w, size + 6, { 0.05, 0.06, 0.08 }, 0.85)
		Viz.outline(sx - w / 2, sy - size / 2 - 3, w, size + 6, c)
		Viz.text(sx - w / 2 + 4, sy - size / 2, "LEFT", size, "VAR BOLD", text, c)
	end
	for i, p in ipairs(plan.passives) do
		if i > 12 then break end
		local id = p.nodes and p.nodes[#p.nodes]
		badge(self.build.spec.nodes[id], tostring(i), col.accent, 14)
	end
	if plan.rush then
		local id = self:StepTarget(plan.rush.idx)
		badge(self.build.spec.nodes[id], "RUSH", col.lightning, 12)
	end
end

-- Draw ---------------------------------------------------------------------------------------------
function GuideTabClass:Draw(viewPort, inputEvents)
	self.x, self.y, self.width, self.height = viewPort.x, viewPort.y, viewPort.width, viewPort.height
	if not self.scannedAt or GetTime() - self.scannedAt > 5000 then
		local before = self:Guide() and self:Guide().name
		self:ScanGuides()
		if (self:Guide() and self:Guide().name) ~= before or not self.stages then self:RefreshStages() end
	end
	self.controls.autoSync.state = Sync.autoEnabled()
	if self.pending then
		self.pending = self.pending - 1
		if self.pending <= 0 then
			self.pending = nil
			local ok, err = pcall(self.Analyse, self)
			if not ok then self.message = "Analysis failed: " .. tostring(err) end
		end
	end

	self:ProcessControlsInput(inputEvents, viewPort)

	local cursorX, cursorY = GetCursorPos()
	local mx, my = cursorX - viewPort.x, cursorY - viewPort.y
	local panelX, panelY = 0, TOOLBAR_H
	local panelH = viewPort.height - TOOLBAR_H
	local inPanel = mx >= 0 and mx < PANEL_W and my >= panelY and my < viewPort.height
	local overRegion = inPanel and regionAt(self.lastHot, mx, my) or nil
	self.hoverId = overRegion and overRegion.id or nil
	for id, event in ipairs(inputEvents) do
		if inPanel and event.type == "KeyUp" and (event.key == "WHEELUP" or event.key == "WHEELDOWN") then
			self.scrollY = self.scrollY + (event.key == "WHEELUP" and -60 or 60)
			inputEvents[id] = nil
		elseif inPanel and event.type == "KeyDown" and event.key == "LEFTBUTTON" then
			self.pressId = overRegion and overRegion.click and overRegion.id or nil
			inputEvents[id] = nil
		elseif inPanel and event.type == "KeyUp" and event.key == "LEFTBUTTON" then
			if overRegion and overRegion.click and overRegion.id == self.pressId then overRegion.click() end
			self.pressId = nil
			inputEvents[id] = nil
		end
	end
	self.scrollY = m_max(0, m_min(self.scrollY, m_max(0, self.contentHeight - panelH)))

	-- Background and toolbar
	SetViewport(viewPort.x, viewPort.y, viewPort.width, viewPort.height)
	Viz.rect(0, 0, viewPort.width, viewPort.height, col.bg)
	Viz.rect(0, TOOLBAR_H - 1, viewPort.width, 1, col.border)
	local status = Sync.status or ""
	local statusCol = Sync.ok == false and col.bad or (Sync.busy and col.warn or col.muted)
	Viz.text(330, 34, "LEFT", 13, "VAR", Viz.fit(13, "VAR", status, viewPort.width - 340), statusCol)
	SetViewport()

	-- Tree on the right, with the guide's stage drawn over it
	local treeX = viewPort.x + PANEL_W
	local treeVPabs = { x = treeX, y = viewPort.y + TOOLBAR_H, width = viewPort.width - PANEL_W, height = viewPort.height - TOOLBAR_H }
	local viewer = self.build.treeTab.viewer
	local inTree = cursorX >= treeVPabs.x and cursorY >= treeVPabs.y and cursorX < treeVPabs.x + treeVPabs.width and cursorY < treeVPabs.y + treeVPabs.height
	local entry = self:Entry(self:Guide())
	local shown = self.result and self.stage or self:CurrentStage()
	if entry and shown and entry.treeTab.activeSpec ~= shown.index then
		pcall(entry.treeTab.SetActiveSpec, entry.treeTab, shown.index)
	end
	local origGetCursorPos = GetCursorPos
	SetViewport(treeVPabs.x, treeVPabs.y, treeVPabs.width, treeVPabs.height)
	GetCursorPos = function()
		local x, y = origGetCursorPos()
		return x - treeVPabs.x, y - treeVPabs.y
	end
	local treeVP = { x = 0, y = 0, width = treeVPabs.width, height = treeVPabs.height }
	self.treeVP = treeVP
	viewer.compareSpec = entry and entry.spec or nil
	local ok, err = pcall(viewer.Draw, viewer, self.build, treeVP, inTree and inputEvents or { })
	viewer.compareSpec = nil
	GetCursorPos = origGetCursorPos
	if ok then pcall(self.DrawPathNumbers, self, treeVP) end
	-- legend
	Viz.rect(8, 8, 330, 22, col.bg, 0.85)
	Viz.text(14, 11, "LEFT", 13, "VAR", "^x5CD677green^7 = take it   ^xF55454red^7 = not in the guide   ^x4FD1C2 1 2 3^7 = order", col.text)
	SetViewport()
	if not ok then self.message = "Tree: " .. tostring(err) end

	-- Panel on the left
	self.hot = { }
	SetViewport(viewPort.x, viewPort.y + panelY, PANEL_W, panelH)
	Viz.rect(0, 0, PANEL_W, panelH, col.bg)
	Viz.rect(PANEL_W - 1, 0, 1, panelH, col.border)
	local y = 12 - self.scrollY
	if self.message then
		local lines = { self.message }
		Viz.softRect(8, y - 2, PANEL_W - 24, 22, Viz.mix(col.card, col.warn, 0.18))
		Viz.text(14, y + 1, "LEFT", 13, "VAR", Viz.fit(13, "VAR", lines[1], PANEL_W - 36), col.warn)
		self:Hot("msg", 8, y - 2, PANEL_W - 24, 22, { "^7" .. self.message })
		y = y + 30
	end
	local hotBase = #self.hot
	local okPanel, h = pcall(self.DrawPanel, self, 16, y, PANEL_W - 40)
	if not okPanel then
		Viz.text(16, y, "LEFT", 13, "VAR", "Error: " .. tostring(h), col.bad)
		h = 40
	end
	-- regions were registered relative to the panel viewport: shift into tab coordinates
	for i = 1, #self.hot do self.hot[i].y = self.hot[i].y + panelY end
	self.contentHeight = (y + self.scrollY) + h + 20
	SetViewport()
	self.lastHot = self.hot

	-- Tooltip for the region under the cursor
	if overRegion and overRegion.tip then
		local tt = self.tooltip
		tt:Clear()
		for _, line in ipairs(overRegion.tip) do tt:AddLine(14, line) end
		SetDrawLayer(nil, 100)
		tt:Draw(viewPort.x + overRegion.x, viewPort.y + overRegion.y, overRegion.w, overRegion.h, main.viewPort)
		SetDrawLayer(nil, 0)
	end

	self:DrawControls(viewPort)
end

return GuideTabClass
