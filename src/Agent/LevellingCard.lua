-- Agent Edition: Overview "Levelling" card (Stage 7), shown while the character is
-- below level 90. Level and act (PoB's own estimate from the allocated points),
-- resistances after the next act penalty, and the next steps of the levelling coach
-- (Agent/Handlers/Levelling.lua, levelling_next: no simulations, so it is cheap).
-- Follows the guide picked in the Guide tab when one is loaded there.
-- Recomputed only when the build changes (level, points, items, skills), at most every 2 s.
local Viz = LoadModule("Agent/Viz")
local col = Viz.col
local m_floor = math.floor

local LevellingCard = { }

LevellingCard.height = 262
LevellingCard.maxLevel = 90

function LevellingCard.show(build)
	return (tonumber(build and build.characterLevel) or 100) < LevellingCard.maxLevel
end

local function handlers()
	local server = launch and launch.agentServer
	return server and server.handlers
end

local function signature(build)
	local spec = build.spec
	local points = spec and select(1, spec:CountAllocNodes()) or 0
	local items, groups = 0, #(build.skillsTab and build.skillsTab.socketGroupList or { })
	for _, slot in pairs(build.itemsTab and build.itemsTab.slots or { }) do items = items + (slot.selItemId or 0) end
	local input = build.configTab and build.configTab.input or { }
	return table.concat({ tostring(build.characterLevel), points, items, groups, tostring(input.resistancePenalty), tostring(input.bandit),
		tostring(build.guideTab and build.guideTab.controls and build.guideTab.controls.guideSelect and build.guideTab.controls.guideSelect.selIndex) }, "|")
end

-- The guide picked in the Guide tab, read as its own build (the tab caches it).
local function guideStages(build, h)
	local tab = build.guideTab
	if not tab or not tab.Guide or not tab.Entry then return nil end
	local ok, entry = pcall(function() return tab:Entry(tab:Guide()) end)
	if not ok or not entry then return nil end
	local res = h._withBuild(entry, h.levelling_guide_stages, { })
	return res and res.ok and res or nil
end

local cache = setmetatable({ }, { __mode = "k" })
local function compute(build, force)
	local now = GetTime and GetTime() or 0
	local c = cache[build]
	local sig = signature(build)
	if c and not force and (c.sig == sig or now - c.at < 2000) then return c.data end
	local h = handlers()
	local data
	if h and h.levelling_next and h._withBuild then
		local guide = guideStages(build, h)
		data = h._withBuild(build, h.levelling_next, { guide = guide, limit = 5 })
	end
	cache[build] = { sig = sig, at = now, data = data }
	return data
end

-- The card's data for a build (also used by the headless test).
LevellingCard.data = function(build, force) return compute(build, force) end

local KIND = { ["quest points"] = "QUEST", resists = "RESIST", lab = "LAB", bandit = "BANDIT", swap = "SWAP", gem = "GEM", links = "LINKS", boots = "BOOTS", passives = "TREE" }
local VIEW = { ["quest points"] = "TREE", passives = "TREE", gem = "SKILLS", swap = "SKILLS", links = "ITEMS", boots = "ITEMS", resists = "ITEMS", bandit = "CONFIG" }

-- tab: the OverviewTab (for Card / Hot / IsHot).
function LevellingCard.draw(tab, x, y, w, h)
	local data = compute(tab.build)
	local me = data and data.ok and data.me
	local note = me and string.format("level %d, %s", me.level, me.act >= 11 and "maps" or ("Act " .. me.act)) or nil
	local tip = { "^7Levelling coach: your next steps through the campaign.",
		"^8Act = PoB's estimate from your passive points (sync the character to keep it current).",
		"^8Ask your AI for the act-by-act plan: \"make me a levelling plan\"." }
	local cx, cy, cw, ch = tab:Card("cLevelling", x, y, w, h, "Levelling", note, tip, function() tab.build.viewMode = "TREE" end)
	if not me then
		Viz.text(cx, cy, "LEFT", 14, "VAR", "Levelling steps appear here.", col.text)
		Viz.text(cx, cy + 22, "LEFT", 13, "VAR", (data and data.error) and Viz.fit(13, "VAR", tostring(data.error), cw) or "The agent link is not running in this window.", col.muted)
		return
	end
	local from = data.from == "guide" and ("Following " .. tostring(data.guideName or "the guide"):gsub("^Guide %- ", "") .. (data.stageNow and (", stage \"" .. tostring(data.stageNow.title) .. "\"") or ""))
		or "No guide picked (Guide tab): planned from this build"
	Viz.text(cx, cy, "LEFT", 12, "VAR", Viz.fit(12, "VAR", from, cw), col.muted)

	-- Resistances now and after the next act penalty.
	local r = data.resists or { }
	local ry = cy + 18
	local label = r.nextAfterAct and string.format("After Act %d (%d%%):", r.nextAfterAct, r.nextPenalty) or "Resistances:"
	Viz.text(cx, ry, "LEFT", 13, "VAR", label, col.muted)
	local rx = cx + Viz.textWidth(13, "VAR", label) + 8
	local tipLines = { "^7Resistances " .. (r.nextAfterAct and ("after finishing Act " .. r.nextAfterAct) or "now") .. " (PoB's numbers)" }
	for _, e in ipairs(r.elements or { }) do
		local v = r.nextAfterAct and e.after or e.now
		local miss = r.nextAfterAct and e.missingAfter or e.missingNow
		local c = e.name == "Chaos" and col.muted or ((miss or 0) > 0 and col.bad or col.good)
		local s = string.format("%s %d%%", e.name:sub(1, 1), m_floor(v or 0))
		Viz.text(rx, ry, "LEFT", 13, "VAR BOLD", s, c)
		rx = rx + Viz.textWidth(13, "VAR BOLD", s) + 10
		table.insert(tipLines, string.format("^7%s: now %d%%, %s%d%% (cap %d%%)", e.name, m_floor(e.now or 0), r.nextAfterAct and "then " or "", m_floor(v or 0), m_floor(e.max or 0)))
	end
	for _, q in ipairs(r.quotes or { }) do table.insert(tipLines, "^8\"" .. q .. "\"") end
	if r.source then table.insert(tipLines, "^8poewiki: " .. tostring(r.source.title) .. (r.source.outdated and " (page older than the current patch)" or "")) end
	if r.configNote then table.insert(tipLines, "^xF5A742" .. r.configNote) end
	tab:Hot("lvres", cx - 4, ry - 2, cw + 8, 18, tipLines, "CALCS")

	-- Next steps.
	local ny = ry + 24
	Viz.text(cx, ny, "LEFT", 12, "VAR", "NEXT", col.muted)
	local steps = data.next or { }
	if #steps == 0 then Viz.text(cx, ny + 18, "LEFT", 13, "VAR", "Nothing urgent: keep levelling.", col.muted) end
	for i, s in ipairs(steps) do
		if i > 5 then break end
		local sy = ny + 16 + (i - 1) * 30
		local id = "lvs" .. i
		local hot = tab:IsHot(id)
		Viz.softRect(cx - 4, sy, cw + 8, 27, hot and col.cardHi or col.bg, hot and 1 or 0.6)
		Viz.text(cx + 2, sy + 1, "LEFT", 11, "VAR", KIND[s.kind] or tostring(s.kind or ""):upper(), col.accent)
		Viz.text(cx + 2, sy + 12, "LEFT", 13, "VAR", Viz.fit(13, "VAR", tostring(s.text or "?"), cw - 4), col.text)
		tab:Hot(id, cx - 4, sy, cw + 8, 27, function(tt)
			tt:AddLine(15, "^7" .. tostring(s.text or "?"))
			if s.source then tt:AddLine(13, "^8Fact source: poewiki (" .. tostring(s.source) .. "), game " .. tostring(data.data and data.data.gameVersion or "?")) end
			tt:AddLine(13, "^8Numbers: PoB. Ask your AI for the full act-by-act plan.")
		end, VIEW[s.kind])
	end
	local d = data.data or { }
	Viz.text(cx, y + h - 20, "LEFT", 11, "VAR", Viz.fit(11, "VAR", string.format("Facts: poewiki, game %s, read %s  |  hidden from level %d", tostring(d.gameVersion or "?"), tostring(d.generated or "?"), LevellingCard.maxLevel), cw), col.muted)
end

return LevellingCard
