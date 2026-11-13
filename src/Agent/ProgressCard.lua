-- Agent Edition: Overview "Progress" card (Stage 2).
-- Draws the timeline of a character synced from pathofexile.com by agent-mcp's
-- character_sync tool. agent-mcp writes <user folder>/AgentCache/history/index.json;
-- this card only reads it (re-read every few seconds, so a sync shows up at once).
-- The build is matched to its character through PoB's own lastCharacterHash
-- (sha1 of the character name, set by every character import).
local Viz = LoadModule("Agent/Viz")
local dkjson = require("dkjson")
local col = Viz.col
local m_max, m_min, m_floor = math.max, math.min, math.floor

local Progress = { }

local cache = { at = -1e9, data = nil }
local function index()
	local now = GetTime and GetTime() or 0
	if now - cache.at < 3000 and cache.at > 0 then return cache.data end
	cache.at = now
	cache.data = nil
	local base = main and main.userPath
	if not base then return nil end
	local f = io.open(base .. "AgentCache/history/index.json", "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	local ok, data = pcall(dkjson.decode, text)
	if ok and type(data) == "table" then cache.data = data end
	return cache.data
end

local function entryFor(build)
	local data = index()
	local hash = build.importTab and build.importTab.lastCharacterHash
	local chars = data and data.characters
	if type(chars) ~= "table" then return nil, data end
	return hash and chars[hash] or nil, data
end

-- A sparkline: thin segments between the points, a dot on the last one.
local function spark(x, y, w, h, values, c)
	local n = #values
	if n == 0 then return end
	local lo, hi = values[1], values[1]
	for _, v in ipairs(values) do lo = m_min(lo, v) hi = m_max(hi, v) end
	if hi - lo < 1e-9 then lo, hi = lo - 1, hi + 1 end
	local function px(i) return x + (n == 1 and w or (i - 1) / (n - 1) * w) end
	local function py(v) return y + h - (v - lo) / (hi - lo) * h end
	Viz.rect(x, y + h, w, 1, col.track)
	SetDrawColor(c[1], c[2], c[3], 1)
	for i = 2, n do
		local x1, y1, x2, y2 = px(i - 1), py(values[i - 1]), px(i), py(values[i])
		DrawImageQuad(nil, x1, y1 - 1, x2, y2 - 1, x2, y2 + 1, x1, y1 + 1)
	end
	Viz.rect(px(n) - 2, py(values[n]) - 2, 5, 5, c)
end

local function change(first, last)
	if not first or first == 0 then return "" end
	local d = (last - first) / math.abs(first) * 100
	if math.abs(d) < 0.05 then return "" end
	return string.format("%s%.0f%%", d >= 0 and "+" or "", d)
end

local function stamp(at)
	return tostring(at or ""):sub(1, 16):gsub("T", " ")
end

-- tab: the OverviewTab (for Card / Hot / IsHot).
function Progress.draw(tab, x, y, w, h)
	local e, data = entryFor(tab.build)
	local timeline = e and e.timeline or { }
	local note = #timeline > 0 and (#timeline .. (#timeline == 1 and " sync" or " syncs") .. ", last " .. stamp(timeline[#timeline].at) .. " UTC") or nil
	local cx, cy, cw, ch = tab:Card("cProg", x, y, w, h, "Progress", note, nil, nil)
	if #timeline == 0 then
		Viz.text(cx, cy, "LEFT", 14, "VAR", "This build is not synced with a character yet.", col.text)
		Viz.text(cx, cy + 22, "LEFT", 13, "VAR", "Ask your AI: \"sync my character\" (account Name#1234", col.muted)
		Viz.text(cx, cy + 38, "LEFT", 13, "VAR", "and character name). It imports from your public", col.muted)
		Viz.text(cx, cy + 54, "LEFT", 13, "VAR", "pathofexile.com profile into \"<character> - synced\".", col.muted)
		local others = { }
		for _, c in pairs(data and data.characters or { }) do if type(c) == "table" and c.name then table.insert(others, c.name) end end
		if #others > 0 then
			table.sort(others)
			Viz.text(cx, cy + 80, "LEFT", 13, "VAR", Viz.fit(13, "VAR", "Synced: " .. table.concat(others, ", ") .. " (open its build)", cw), col.muted)
		end
		return
	end
	local rows = {
		{ key = "dps", label = "DPS", c = col.fire },
		{ key = "ehp", label = "EHP", c = col.accent },
		{ key = "maxHit", label = "Max hit", c = col.physical },
		{ key = "level", label = "Level", c = col.lightning },
	}
	local labelW, valueW = 62, 96
	local rowH = 28
	local first, last = timeline[1], timeline[#timeline]
	for i, r in ipairs(rows) do
		local ry = cy + (i - 1) * rowH
		local values = { }
		for _, p in ipairs(timeline) do table.insert(values, tonumber(p[r.key]) or 0) end
		local hot = tab:IsHot("prg" .. i)
		if hot then Viz.softRect(cx - 4, ry - 2, cw + 8, rowH, col.track, 0.6) end
		Viz.text(cx, ry + 4, "LEFT", 14, "VAR", r.label, col.muted)
		Viz.text(cx + labelW + valueW - 8, ry + 2, "RIGHT", 16, "VAR BOLD", r.key == "level" and tostring(values[#values]) or Viz.num(values[#values]), col.text)
		local ch = change(tonumber(first[r.key]), tonumber(last[r.key]))
		if r.key == "level" and values[1] ~= values[#values] then ch = "+" .. (values[#values] - values[1]) end
		local sx = cx + labelW + valueW
		local sw = cw - labelW - valueW - 44
		spark(sx, ry + 3, sw, rowH - 10, values, r.c)
		if ch ~= "" then
			local good = ch:sub(1, 1) == "+"
			Viz.text(cx + cw, ry + 4, "RIGHT", 13, "VAR BOLD", ch, good and col.good or col.bad)
		end
		tab:Hot("prg" .. i, cx - 4, ry - 2, cw + 8, rowH, function(tt)
			tt:AddLine(16, "^7" .. r.label .. " at each sync (PoB's numbers)")
			local from = m_max(1, #timeline - 11)
			for k = from, #timeline do
				local p = timeline[k]
				tt:AddLine(14, string.format("^8%s  ^7%s", stamp(p.at), r.key == "level" and tostring(p.level) or Viz.num(tonumber(p[r.key]) or 0)))
			end
			if from > 1 then tt:AddLine(14, "^8(" .. (from - 1) .. " earlier syncs; ask your AI for the full history)") end
		end, nil)
	end
	local sy = cy + #rows * rowH + 2
	local summary = last.summary and ("Last sync: " .. last.summary) or ""
	Viz.text(cx, sy, "LEFT", 13, "VAR", Viz.fit(13, "VAR", summary, cw), col.muted)
end

return Progress
