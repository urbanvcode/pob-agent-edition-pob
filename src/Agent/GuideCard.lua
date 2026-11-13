-- Agent Edition: Overview "Guide" card (Stage 3).
-- Shows how close the open build is to the guide stage it follows: passives,
-- gems and key items matched, DPS/EHP against the guide, and the next 3 steps.
-- agent-mcp's guide_compare / guide_next_steps write
-- <user folder>/AgentCache/guide/card.json; this card only reads it
-- (re-read every few seconds, so a new comparison shows up at once).
local Viz = LoadModule("Agent/Viz")
local dkjson = require("dkjson")
local col = Viz.col
local m_max, m_min, m_floor = math.max, math.min, math.floor

local GuideCard = { }

GuideCard.height = 292

local cache = { at = -1e9, data = nil }
local function card()
	local now = GetTime and GetTime() or 0
	if cache.at > 0 and now - cache.at < 3000 then return cache.data end
	cache.at = now
	cache.data = nil
	local base = main and main.userPath
	if not base then return nil end
	local f = io.open(base .. "AgentCache/guide/card.json", "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	local ok, data = pcall(dkjson.decode, text)
	if ok and type(data) == "table" then cache.data = data end
	return cache.data
end

local function pct(pair)
	local have, total = tonumber(pair and pair[1]) or 0, tonumber(pair and pair[2]) or 0
	if total <= 0 then return 1, "-" end
	return have / total, string.format("%d/%d", have, total)
end

local function signed(v)
	return string.format("%+.1f%%", tonumber(v) or 0)
end

local KIND = { passives = "TREE", mastery = "TREE", gem = "GEM", ["gem levels"] = "GEM", ["skill group"] = "SKILL", item = "ITEM", jewel = "JEWEL" }

-- tab: the OverviewTab (for Card / Hot / IsHot).
function GuideCard.draw(tab, x, y, w, h)
	local data = card()
	local mine = data and data.build == tab.build.buildName
	local note
	if data and data.guide then
		note = (data.guide:gsub("^Guide %- ", ""))
		if not mine then note = "for " .. tostring(data.build) end
	end
	local title = (data and data.stage and mine) and ("Guide - " .. data.stage) or "Guide"
	local cx, cy, cw, ch = tab:Card("cGuide", x, y, w, h, title, note, { "^7Open the Guide tab: the guide over your tree, next steps and Analyse." }, function() tab.build.viewMode = "GUIDE" end)
	if not data or not mine then
		Viz.text(cx, cy, "LEFT", 14, "VAR", "Follow a build guide stage by stage.", col.text)
		Viz.text(cx, cy + 22, "LEFT", 13, "VAR", "Paste the guide's PoB link (pobb.in, poe.ninja,", col.muted)
		Viz.text(cx, cy + 38, "LEFT", 13, "VAR", "pastebin) to your AI and ask: \"import this guide", col.muted)
		Viz.text(cx, cy + 54, "LEFT", 13, "VAR", "and tell me what I'm missing\".", col.muted)
		if data and data.build then
			Viz.text(cx, cy + 80, "LEFT", 13, "VAR", Viz.fit(13, "VAR", "Last comparison was for \"" .. tostring(data.build) .. "\" (open that build).", cw), col.muted)
		end
		return
	end

	-- Matched: passives, gems, key items.
	local rows = {
		{ label = "Passives", pair = data.match and data.match.passives, c = col.accent, view = "TREE" },
		{ label = "Gems", pair = data.match and data.match.gems, c = col.good, view = "SKILLS" },
		{ label = "Key items", pair = data.match and data.match.items, c = col.warn, view = "ITEMS" },
	}
	local labelW, countW = 74, 62
	for i, r in ipairs(rows) do
		local ry = cy + (i - 1) * 22
		local frac, count = pct(r.pair)
		Viz.text(cx, ry + 2, "LEFT", 14, "VAR", r.label, col.muted)
		Viz.bar(cx + labelW, ry + 6, cw - labelW - countW - 44, 8, frac, r.c)
		Viz.text(cx + cw - countW, ry + 2, "RIGHT", 13, "VAR", count, col.muted)
		Viz.text(cx + cw, ry + 1, "RIGHT", 14, "VAR BOLD", string.format("%d%%", m_floor(frac * 100 + 0.5)), col.text)
		tab:Hot("gdm" .. i, cx - 4, ry, cw + 8, 22, { "^7" .. r.label .. " matching the guide stage: " .. count, "^8Click to open the " .. r.view:lower() .. " tab" }, r.view)
	end

	-- DPS and EHP against the guide.
	local sy = cy + 3 * 22 + 6
	local function vs(label, pair, xx)
		local a, b = tonumber(pair and pair[1]) or 0, tonumber(pair and pair[2]) or 0
		local share = b > 0 and string.format("%d%%", m_floor(a / b * 100 + 0.5)) or "-"
		Viz.text(xx, sy, "LEFT", 13, "VAR", label, col.muted)
		Viz.text(xx + 34, sy - 1, "LEFT", 14, "VAR BOLD", share, col.text)
		Viz.text(xx + 76, sy, "LEFT", 12, "VAR", Viz.fit(12, "VAR", Viz.num(a) .. " / " .. Viz.num(b), cw / 2 - 80), col.muted)
	end
	vs("DPS", data.dps, cx)
	vs("EHP", data.ehp, cx + cw / 2)
	tab:Hot("gdvs", cx - 4, sy - 2, cw + 8, 18, { "^7You against the guide stage (PoB's numbers, your config)", "^8DPS " .. Viz.num(tonumber(data.dps and data.dps[1]) or 0) .. " / " .. Viz.num(tonumber(data.dps and data.dps[2]) or 0), "^8EHP " .. Viz.num(tonumber(data.ehp and data.ehp[1]) or 0) .. " / " .. Viz.num(tonumber(data.ehp and data.ehp[2]) or 0) }, nil)

	-- Next 3 steps.
	local ny = sy + 24
	Viz.text(cx, ny, "LEFT", 12, "VAR", "NEXT STEPS", col.muted)
	local steps = data.next or { }
	if #steps == 0 then
		Viz.text(cx, ny + 18, "LEFT", 13, "VAR", "Ask your AI: \"what next toward my guide?\"", col.muted)
	end
	for i, s in ipairs(steps) do
		if i > 3 then break end
		local ry = ny + 16 + (i - 1) * 34
		local id = "gds" .. i
		local hot = tab:IsHot(id)
		Viz.softRect(cx - 4, ry, cw + 8, 30, hot and col.cardHi or col.bg, hot and 1 or 0.6)
		Viz.text(cx + 2, ry + 2, "LEFT", 14, "VAR BOLD", tostring(i), col.accent)
		Viz.text(cx + 18, ry + 3, "LEFT", 11, "VAR", KIND[s.kind] or tostring(s.kind or ""):upper(), col.muted)
		local chips = { }
		if math.abs(tonumber(s.dpsPct) or 0) >= 0.05 then table.insert(chips, { "DPS " .. signed(s.dpsPct), (s.dpsPct or 0) >= 0 and col.accent or col.bad }) end
		if math.abs(tonumber(s.ehpPct) or 0) >= 0.05 then table.insert(chips, { "EHP " .. signed(s.ehpPct), (s.ehpPct or 0) >= 0 and col.good or col.bad }) end
		local chipX = cx + cw
		for k = #chips, 1, -1 do
			local label, c = chips[k][1], chips[k][2]
			local cwid = DrawStringWidth(12, "VAR BOLD", label) + 10
			chipX = chipX - cwid
			Viz.softRect(chipX, ry + 2, cwid, 14, Viz.mix(col.card, c, 0.25))
			Viz.text(chipX + 5, ry + 3, "LEFT", 12, "VAR BOLD", label, c)
			chipX = chipX - 4
		end
		Viz.text(cx + 18, ry + 15, "LEFT", 13, "VAR", Viz.fit(13, "VAR", tostring(s.text or "?"), cw - 18 - (s.price and 90 or 0)), col.text)
		if s.price then Viz.text(cx + cw, ry + 15, "RIGHT", 12, "VAR BOLD", Viz.fit(12, "VAR BOLD", (s.price:gsub(" %(poe%.ninja%)", "")), 88), col.warn) end
		local link = type(s.link) == "string" and s.link:match("^https://www%.pathofexile%.com/trade/") and s.link or nil
		tab:Hot(id, cx - 4, ry, cw + 8, 30, function(tt)
			tt:AddLine(16, "^7" .. tostring(s.text or "?"))
			tt:AddLine(15, string.format("^7In your build: ^x4FD1C2DPS %s  ^x5CD677EHP %s ^8(PoB simulation)", signed(s.dpsPct), signed(s.ehpPct)))
			if s.price then tt:AddLine(14, "^7Price: ^xF5A742" .. s.price) end
			tt:AddLine(13, link and "^x4FD1C2Click to open the instant-buyout search on pathofexile.com" or ("^x4FD1C2Click to open the " .. tostring(s.view or "TREE"):lower() .. " tab"))
			tt:AddLine(13, "^8Ask your AI for the full list: \"what next toward my guide?\"")
		end, function()
			if link then OpenURL(link) elseif s.view then tab.build.viewMode = s.view end
		end)
	end
	local at = tostring(data.at or ""):sub(1, 16):gsub("T", " ")
	Viz.text(cx, y + h - 20, "LEFT", 11, "VAR", Viz.fit(11, "VAR", (data.focus and ("Focus: " .. data.focus .. "  |  ") or "") .. "Stage " .. tostring(data.stageIndex or "?") .. "/" .. tostring(data.stages or "?") .. (data.levelling and " (levelling)" or "") .. "  |  " .. at .. " UTC", cw), col.muted)
end

return GuideCard
