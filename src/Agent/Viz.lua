-- Agent Edition: drawing helpers for dashboards and infographics.
-- Everything is drawn with SimpleGraphic primitives (DrawImage / DrawImageQuad /
-- DrawString) so it works in any PoB build without extra assets.

local m_sin, m_cos, m_pi, m_max, m_min, m_floor, m_abs = math.sin, math.cos, math.pi, math.max, math.min, math.floor, math.abs

local Viz = { }

-- Palette ------------------------------------------------------------------
Viz.col = {
	bg        = { 0.055, 0.063, 0.082 },
	card      = { 0.090, 0.102, 0.133 },
	cardHi    = { 0.110, 0.125, 0.165 },
	border    = { 0.180, 0.200, 0.255 },
	track     = { 0.160, 0.176, 0.220 },
	text      = { 0.910, 0.925, 0.950 },
	muted     = { 0.560, 0.600, 0.680 },
	accent    = { 0.310, 0.820, 0.760 },
	good      = { 0.360, 0.840, 0.470 },
	warn      = { 0.980, 0.720, 0.260 },
	bad       = { 0.960, 0.330, 0.330 },
	fire      = { 0.960, 0.400, 0.260 },
	cold      = { 0.380, 0.640, 0.990 },
	lightning = { 0.990, 0.840, 0.300 },
	chaos     = { 0.820, 0.380, 0.860 },
	physical  = { 0.820, 0.740, 0.620 },
	life      = { 0.880, 0.280, 0.330 },
	es        = { 0.480, 0.780, 0.980 },
	mana      = { 0.340, 0.480, 0.980 },
	str       = { 0.900, 0.350, 0.300 },
	dex       = { 0.380, 0.820, 0.420 },
	int       = { 0.400, 0.560, 0.980 },
}

function Viz.hex(c)
	return string.format("^x%02X%02X%02X", m_floor(c[1] * 255 + 0.5), m_floor(c[2] * 255 + 0.5), m_floor(c[3] * 255 + 0.5))
end

function Viz.mix(a, b, t)
	return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

-- Primitives ---------------------------------------------------------------
function Viz.rect(x, y, w, h, c, a)
	if w <= 0 or h <= 0 then return end
	SetDrawColor(c[1], c[2], c[3], a or 1)
	DrawImage(nil, x, y, w, h)
end

-- Rectangle with softened (clipped) corners.
function Viz.softRect(x, y, w, h, c, a)
	if w <= 4 or h <= 4 then return Viz.rect(x, y, w, h, c, a) end
	SetDrawColor(c[1], c[2], c[3], a or 1)
	DrawImage(nil, x + 2, y, w - 4, h)
	DrawImage(nil, x, y + 2, 2, h - 4)
	DrawImage(nil, x + w - 2, y + 2, 2, h - 4)
	DrawImage(nil, x + 1, y + 1, 1, h - 2)
	DrawImage(nil, x + w - 2, y + 1, 1, h - 2)
end

function Viz.outline(x, y, w, h, c, a)
	SetDrawColor(c[1], c[2], c[3], a or 1)
	DrawImage(nil, x + 2, y, w - 4, 1)
	DrawImage(nil, x + 2, y + h - 1, w - 4, 1)
	DrawImage(nil, x, y + 2, 1, h - 4)
	DrawImage(nil, x + w - 1, y + 2, 1, h - 4)
	DrawImage(nil, x + 1, y + 1, 1, 1)
	DrawImage(nil, x + w - 2, y + 1, 1, 1)
	DrawImage(nil, x + 1, y + h - 2, 1, 1)
	DrawImage(nil, x + w - 2, y + h - 2, 1, 1)
end

-- align: "LEFT", "RIGHT" (x is the right edge) or "CENTER" (x is the centre).
-- (SimpleGraphic's own RIGHT/CENTER are relative to the viewport, hence the _X forms.)
local alignMap = { LEFT = "LEFT", RIGHT = "RIGHT_X", CENTER = "CENTER_X" }
function Viz.text(x, y, align, size, font, str, c)
	DrawString(x, y, alignMap[align] or align, size, font, (c and Viz.hex(c) or "") .. str)
end

-- Shorten str with "..." until it fits maxW pixels.
function Viz.fit(size, font, str, maxW)
	if DrawStringWidth(size, font, str) <= maxW then return str end
	while #str > 1 and DrawStringWidth(size, font, str .. "...") > maxW do str = str:sub(1, -2) end
	return str .. "..."
end

function Viz.textWidth(size, font, str)
	return DrawStringWidth(size, font, str)
end

-- A card: rounded panel with a title row. Returns the content box.
function Viz.card(x, y, w, h, title, note)
	Viz.softRect(x, y, w, h, Viz.col.card)
	Viz.outline(x, y, w, h, Viz.col.border)
	Viz.rect(x + 12, y + 30, w - 24, 1, Viz.col.border)
	Viz.text(x + 12, y + 8, "LEFT", 16, "VAR BOLD", title, Viz.col.text)
	if note then
		local room = w - 24 - DrawStringWidth(16, "VAR BOLD", title) - 16
		if room > 40 then
			Viz.text(x + w - 12, y + 10, "RIGHT", 14, "VAR", Viz.fit(14, "VAR", note, room), Viz.col.muted)
		end
	end
	return x + 12, y + 40, w - 24, h - 52
end

-- Horizontal meter. frac 0..1 (clamped).
function Viz.bar(x, y, w, h, frac, c, track)
	Viz.softRect(x, y, w, h, track or Viz.col.track)
	frac = m_max(0, m_min(1, frac or 0))
	if frac > 0 then
		Viz.softRect(x, y, m_max(3, w * frac), h, c)
	end
end

-- Filled annulus sector from angle a0 to a1 (radians, 0 = 12 o'clock, clockwise).
function Viz.arc(cx, cy, r0, r1, a0, a1, c, a)
	if a1 <= a0 then return end
	SetDrawColor(c[1], c[2], c[3], a or 1)
	local steps = m_max(2, m_floor((a1 - a0) / (m_pi * 2) * 72 + 0.5))
	local step = (a1 - a0) / steps
	for i = 0, steps - 1 do
		local t0, t1 = a0 + step * i, a0 + step * (i + 1)
		local s0, c0, s1, c1 = m_sin(t0), -m_cos(t0), m_sin(t1), -m_cos(t1)
		DrawImageQuad(nil,
			cx + s0 * r1, cy + c0 * r1,
			cx + s1 * r1, cy + c1 * r1,
			cx + s1 * r0, cy + c1 * r0,
			cx + s0 * r0, cy + c0 * r0)
	end
end

-- Ring gauge: track ring plus filled portion; frac 0..1.
function Viz.ring(cx, cy, r, thickness, frac, c)
	frac = m_max(0, m_min(1, frac or 0))
	Viz.arc(cx, cy, r - thickness, r, 0, m_pi * 2, Viz.col.track)
	if frac > 0 then
		Viz.arc(cx, cy, r - thickness, r, 0, m_pi * 2 * frac, c)
	end
end

-- Donut chart: segments = { { value = n, col = {r,g,b} }, ... }
function Viz.donut(cx, cy, r, thickness, segments)
	local total = 0
	for _, s in ipairs(segments) do total = total + m_max(0, s.value or 0) end
	if total <= 0 then
		Viz.arc(cx, cy, r - thickness, r, 0, m_pi * 2, Viz.col.track)
		return
	end
	local a = 0
	local gap = #segments > 1 and 0.025 or 0
	for _, s in ipairs(segments) do
		local v = m_max(0, s.value or 0)
		if v > 0 then
			local span = m_pi * 2 * v / total
			Viz.arc(cx, cy, r - thickness, r, a + gap / 2, a + span - gap / 2, s.col)
			a = a + span
		end
	end
end

-- Small coloured square used in legends.
function Viz.swatch(x, y, c, size)
	Viz.softRect(x, y, size or 10, size or 10, c)
end

-- Formatting ---------------------------------------------------------------
function Viz.num(v, dec)
	v = tonumber(v) or 0
	local a = m_abs(v)
	local s
	if a >= 1e9 then s = string.format("%.2fB", v / 1e9)
	elseif a >= 1e6 then s = string.format("%.2fM", v / 1e6)
	elseif a >= 1e4 then s = string.format("%.1fk", v / 1e3)
	elseif a >= 1e3 then s = string.format("%.2fk", v / 1e3)
	else s = string.format("%." .. (dec or 0) .. "f", v) end
	return s
end

function Viz.pct(v, dec)
	return string.format("%." .. (dec or 0) .. "f%%", tonumber(v) or 0)
end

-- Is the mouse inside a rect (coordinates relative to the current viewport origin)?
function Viz.hover(mx, my, x, y, w, h)
	return mx and mx >= x and mx < x + w and my >= y and my < y + h
end

return Viz
