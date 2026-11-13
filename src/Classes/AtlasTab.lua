-- Path of Building - Agent Edition
--
-- Class: Atlas Tab
-- Atlas passive tree planner using GGG's official atlas export (latest
-- league). Pan with drag, zoom with the wheel, click to allocate (takes the
-- shortest path), click an allocated node to remove it (and anything that
-- depended on it). Saved inside the build as <AtlasTree>.
--
local AtlasData = LoadModule("Agent/AtlasData")
local Viz = LoadModule("Agent/Viz")
local col = Viz.col
local m_max, m_min, m_floor, m_abs, m_sqrt, m_pi = math.max, math.min, math.floor, math.abs, math.sqrt, math.pi
local t_insert = table.insert

local GOLD = { 0.86, 0.68, 0.32 }
local PATH = { 0.42, 0.66, 0.98 }
local DIM_LINE = { 0.20, 0.21, 0.25 }

local AtlasTabClass = newClass("AtlasTab", "ControlHost", "Control", function(self, build)
	self.ControlHost()
	self.Control()
	self.build = build
	self.version = AtlasData.latest
	self.alloc = { }
	self.zoom = nil
	self.cx, self.cy = 0, -6000
	self.handles = { }
	self.tooltip = new("Tooltip")
	self.modFlag = false

	self.controls.search = new("EditControl", { "TOPLEFT", self, "TOPLEFT" }, { 8, 8, 260, 20 }, "", "Search", "%c", 100, function(buf)
		self.searchText = buf:lower()
	end, nil, nil, true)
	self.controls.reset = new("ButtonControl", { "LEFT", self.controls.search, "RIGHT" }, { 8, 0, 70, 20 }, "Reset", function()
		main:OpenConfirmPopup("Reset Atlas", "Remove all allocated atlas passives?", "Reset", function()
			self:SetNodes({ })
		end)
	end)
	self.controls.import = new("ButtonControl", { "LEFT", self.controls.reset, "RIGHT" }, { 8, 0, 110, 20 }, "Import link...", function()
		self:OpenImportPopup()
	end)
	self.controls.export = new("ButtonControl", { "LEFT", self.controls.import, "RIGHT" }, { 8, 0, 110, 20 }, "Copy link", function()
		local atlas = self:Data()
		if atlas then
			Copy(AtlasData.encodeLink(atlas, self.alloc))
			self.flash = { text = "Atlas link copied", until_ = GetTime() + 2000 }
		end
	end)
	self.controls.export.tooltipText = "Copies an official pathofexile.com atlas tree link for this setup."
	self.controls.fit = new("ButtonControl", { "LEFT", self.controls.export, "RIGHT" }, { 8, 0, 80, 20 }, "Fit view", function()
		self.zoom = nil
	end)
end)

function AtlasTabClass:Data()
	if self.atlas == nil then
		local atlas, err = AtlasData.load(self.version)
		self.atlas = atlas or false
		self.loadError = err
		if atlas and not next(self.alloc) then self:ResetToStart() end
	end
	return self.atlas or nil
end

function AtlasTabClass:ResetToStart()
	local atlas = self.atlas
	self.alloc = { root = true }
	if atlas and atlas.startId then self.alloc[atlas.startId] = true end
end

-- Points spent (start node and root are free)
function AtlasTabClass:PointsUsed()
	local atlas = self:Data()
	local n = 0
	for id in pairs(self.alloc) do
		local node = atlas and atlas.nodes[id]
		if node and node.type ~= "root" and node.type ~= "start" and node.type ~= "mastery" then n = n + 1 end
	end
	return n
end

function AtlasTabClass:MarkChanged()
	self.modFlag = true
	self.build.buildFlag = true
end

-- Public API (UI and AI) --------------------------------------------------------
function AtlasTabClass:Allocate(id)
	local atlas = self:Data()
	if not atlas or not atlas.nodes[id] then return nil, "unknown atlas node " .. tostring(id) end
	local path = AtlasData.pathTo(atlas, self.alloc, id)
	if not path then return nil, "node is not reachable" end
	if self:PointsUsed() + #path > atlas.points then
		return nil, string.format("needs %d points, only %d left", #path, atlas.points - self:PointsUsed())
	end
	for _, pid in ipairs(path) do self.alloc[pid] = true end
	if #path > 0 then self:MarkChanged() end
	return path
end

function AtlasTabClass:Deallocate(id)
	local atlas = self:Data()
	if not atlas or not self.alloc[id] then return { } end
	local node = atlas.nodes[id]
	if node.type == "root" or node.type == "start" then return { } end
	local keep = AtlasData.connected(atlas, self.alloc, id)
	local removed = { }
	for aid in pairs(self.alloc) do
		if not keep[aid] then self.alloc[aid] = nil; t_insert(removed, aid) end
	end
	self:MarkChanged()
	return removed
end

-- Replace the whole allocation. Nodes are added in order, pathing as needed.
function AtlasTabClass:SetNodes(ids)
	local atlas = self:Data()
	if not atlas then return nil, self.loadError end
	self:ResetToStart()
	local skipped = { }
	for _, id in ipairs(ids) do
		id = tostring(id)
		local node = atlas.nodes[id]
		if node and node.type ~= "mastery" and node.type ~= "root" then
			-- Imported links are already connected sets; take them as-is first
			self.alloc[id] = true
		else
			t_insert(skipped, id)
		end
	end
	-- Drop anything not connected to the start
	local keep = AtlasData.connected(atlas, self.alloc, nil)
	for aid in pairs(self.alloc) do if not keep[aid] then self.alloc[aid] = nil; t_insert(skipped, aid) end end
	self:MarkChanged()
	return true, skipped
end

function AtlasTabClass:Search(text, limit)
	local atlas = self:Data()
	local res = { }
	if not atlas or not text or text == "" then return res end
	text = text:lower()
	for _, node in ipairs(atlas.list) do
		if node.type ~= "root" and node.type ~= "start" and node.searchText:find(text, 1, true) then
			t_insert(res, node)
			if #res >= (limit or 50) then break end
		end
	end
	return res
end

function AtlasTabClass:AllocatedList()
	local atlas = self:Data()
	local res = { }
	for id in pairs(self.alloc) do
		local n = atlas and atlas.nodes[id]
		if n and n.type ~= "root" and n.type ~= "start" then t_insert(res, n) end
	end
	table.sort(res, function(a, b) return a.name < b.name end)
	return res
end

-- Save / load inside the build ---------------------------------------------------
function AtlasTabClass:Load(xml, dbFileName)
	self.version = xml.attrib.version or AtlasData.latest
	if not AtlasData.load(self.version) then self.version = AtlasData.latest end
	self.atlas = nil
	local ids = { }
	for id in (xml.attrib.nodes or ""):gmatch("[^,]+") do t_insert(ids, id) end
	if self:Data() then self:SetNodes(ids) end
	self.modFlag = false
end

function AtlasTabClass:Save(xml)
	local ids = { }
	for id in pairs(self.alloc) do if id ~= "root" then t_insert(ids, id) end end
	table.sort(ids)
	xml.attrib = { version = self.version, nodes = table.concat(ids, ",") }
	self.modFlag = false
end

function AtlasTabClass:OpenImportPopup()
	local controls = { }
	controls.label = new("LabelControl", nil, { 0, 24, 0, 16 }, "^7Paste an atlas tree link (pathofexile.com atlas planner):")
	controls.edit = new("EditControl", nil, { 0, 44, 560, 20 }, "", nil, nil, nil, nil)
	controls.import = new("ButtonControl", nil, { -50, 76, 90, 20 }, "Import", function()
		local ids, err = AtlasData.decodeLink(controls.edit.buf)
		if not ids then
			controls.label.label = "^xF55454" .. tostring(err)
			return
		end
		local _, skipped = self:SetNodes(ids)
		main:ClosePopup()
		self.flash = { text = string.format("Imported %d atlas passives%s", self:PointsUsed(), (skipped and #skipped > 0) and (" (" .. #skipped .. " skipped)") or ""), until_ = GetTime() + 3000 }
	end)
	controls.cancel = new("ButtonControl", nil, { 50, 76, 90, 20 }, "Cancel", function() main:ClosePopup() end)
	main:OpenPopup(600, 106, "Import Atlas Tree", controls, "import", "edit", "cancel")
end

-- Drawing -------------------------------------------------------------------
function AtlasTabClass:Sheet(key)
	local sprite = self.atlas.sprites[key]
	if not sprite then return nil end
	local h = self.handles[sprite.file]
	if not h then
		h = NewImageHandle()
		h:Load(sprite.file, "MIPMAP")
		self.handles[sprite.file] = h
	end
	return h, sprite
end

-- Draw a named sprite centred at (x, y), scaled from tree units
function AtlasTabClass:DrawSprite(key, name, x, y, scale, alpha, sizeMult)
	local h, sprite = self:Sheet(key)
	if not h or not h:IsValid() then return false end
	local c = sprite.coords[name]
	if not c then return false end
	local w = c.w / sprite.zoom * scale * (sizeMult or 1)
	local hh = c.h / sprite.zoom * scale * (sizeMult or 1)
	SetDrawColor(1, 1, 1, alpha or 1)
	DrawImage(h, x - w / 2, y - hh / 2, w, hh, c.x / sprite.w, c.y / sprite.h, (c.x + c.w) / sprite.w, (c.y + c.h) / sprite.h)
	return true
end

local function line(x1, y1, x2, y2, width, c, a)
	local dx, dy = x2 - x1, y2 - y1
	local len = m_sqrt(dx * dx + dy * dy)
	if len < 0.5 then return end
	local nx, ny = -dy / len * width / 2, dx / len * width / 2
	SetDrawColor(c[1], c[2], c[3], a or 1)
	DrawImageQuad(nil, x1 + nx, y1 + ny, x2 + nx, y2 + ny, x2 - nx, y2 - ny, x1 - nx, y1 - ny)
end

function AtlasTabClass:Draw(viewPort, inputEvents)
	self.x, self.y, self.width, self.height = viewPort.x, viewPort.y, viewPort.width, viewPort.height
	self:ProcessControlsInput(inputEvents, viewPort)
	local atlas = self:Data()

	SetViewport(viewPort.x, viewPort.y, viewPort.width, viewPort.height)
	Viz.rect(0, 0, viewPort.width, viewPort.height, { 0.035, 0.038, 0.05 })
	if not atlas then
		Viz.text(20, 60, "LEFT", 16, "VAR", "Atlas data not found: " .. tostring(self.loadError), col.bad)
		SetViewport()
		self:DrawControls(viewPort)
		return
	end

	-- Fit to view the first time
	local top = 36
	local vw, vh = viewPort.width, viewPort.height - top
	if not self.zoom then
		local tw, th = atlas.maxX - atlas.minX, atlas.maxY - atlas.minY
		self.zoom = m_min(vw / tw, vh / th) * 0.95
		self.cx, self.cy = (atlas.minX + atlas.maxX) / 2, (atlas.minY + atlas.maxY) / 2
	end

	-- Input: drag to pan, wheel to zoom, click to (de)allocate
	local cursorX, cursorY = GetCursorPos()
	local mx, my = cursorX - viewPort.x, cursorY - viewPort.y
	local inside = mx >= 0 and my >= top and mx < viewPort.width and my < viewPort.height
	local function toScreen(tx, ty) return (tx - self.cx) * self.zoom + vw / 2, (ty - self.cy) * self.zoom + vh / 2 + top end
	local function toTree(sx, sy) return (sx - vw / 2) / self.zoom + self.cx, (sy - top - vh / 2) / self.zoom + self.cy end

	for id, event in ipairs(inputEvents) do
		if inside and event.type == "KeyDown" and event.key == "LEFTBUTTON" then
			self.drag = { x = mx, y = my, cx = self.cx, cy = self.cy, moved = false }
			inputEvents[id] = nil
		elseif event.type == "KeyUp" and event.key == "LEFTBUTTON" and self.drag then
			if not self.drag.moved and self.hoverNode then
				local n = self.hoverNode
				if self.alloc[n.id] then self:Deallocate(n.id) else
					local ok, err = self:Allocate(n.id)
					if not ok then self.flash = { text = err, until_ = GetTime() + 2500, bad = true } end
				end
			end
			self.drag = nil
			inputEvents[id] = nil
		elseif inside and event.type == "KeyUp" and (event.key == "WHEELUP" or event.key == "WHEELDOWN") then
			local tx, ty = toTree(mx, my)
			local factor = event.key == "WHEELUP" and 1.2 or 1 / 1.2
			self.zoom = m_max(0.02, m_min(1.2, self.zoom * factor))
			-- keep the point under the cursor fixed
			self.cx = tx - (mx - vw / 2) / self.zoom
			self.cy = ty - (my - top - vh / 2) / self.zoom
			inputEvents[id] = nil
		end
	end
	if self.drag and IsKeyDown("LEFTBUTTON") then
		local dx, dy = mx - self.drag.x, my - self.drag.y
		if m_abs(dx) + m_abs(dy) > 4 then self.drag.moved = true end
		if self.drag.moved then
			self.cx = self.drag.cx - dx / self.zoom
			self.cy = self.drag.cy - dy / self.zoom
		end
	end

	local z = self.zoom
	local search = self.searchText and #self.searchText >= 2 and self.searchText or nil

	-- Hover detection
	self.hoverNode = nil
	if inside and not (self.drag and self.drag.moved) then
		local tx, ty = toTree(mx, my)
		local best, bestD
		for _, node in ipairs(atlas.list) do
			if node.x and node.type ~= "root" and node.type ~= "mastery" then
				local r = (node.type == "keystone" and 70 or (node.type == "notable" or node.type == "wormhole") and 55 or 40)
				local dx, dy = node.x - tx, node.y - ty
				local d = dx * dx + dy * dy
				if d < r * r and (not bestD or d < bestD) then best, bestD = node, d end
			end
		end
		self.hoverNode = best
	end
	local preview = { }
	if self.hoverNode and not self.alloc[self.hoverNode.id] then
		for _, pid in ipairs(AtlasData.pathTo(atlas, self.alloc, self.hoverNode.id) or { }) do preview[pid] = true end
	end
	local removing = { }
	if self.hoverNode and self.alloc[self.hoverNode.id] and self.hoverNode.type ~= "start" then
		local keep = AtlasData.connected(atlas, self.alloc, self.hoverNode.id)
		for id in pairs(self.alloc) do if not keep[id] then removing[id] = true end end
	end

	-- Group art: mastery emblems (decorative, like the in-game atlas)
	for _, node in ipairs(atlas.list) do
		if node.type == "mastery" and node.x then
			local sx, sy = toScreen(node.x, node.y)
			if sx > -200 and sy > -200 and sx < vw + 200 and sy < viewPort.height + 200 then
				self:DrawSprite("mastery", node.icon, sx, sy, z, 0.35)
			end
		end
	end

	-- Connections
	local lw = m_max(1.5, 14 * z)
	for _, e in ipairs(atlas.edges) do
		local a, b = e.a, e.b
		if a.x and b.x then
			local both = self.alloc[a.id] and self.alloc[b.id]
			local pv = (preview[a.id] or self.alloc[a.id]) and (preview[b.id] or self.alloc[b.id]) and (preview[a.id] or preview[b.id])
			local rm = removing[a.id] or removing[b.id]
			local c, alpha = DIM_LINE, 1
			if both then c = rm and col.bad or GOLD elseif pv then c = PATH end
			if a.type == "wormhole" and b.type == "wormhole" then alpha = 0.25 end
			local x1, y1 = toScreen(a.x, a.y)
			local x2, y2 = toScreen(b.x, b.y)
			if a.group == b.group and a.orbit == b.orbit and a.orbit > 0 then
				-- arc along the orbit (shorter way round)
				local g = atlas.groups[tostring(a.group)]
				local gx, gy = toScreen(g.x, g.y)
				local r = m_sqrt((x1 - gx) ^ 2 + (y1 - gy) ^ 2)
				local a0, a1 = a.angle, b.angle
				local d = (a1 - a0) % (2 * m_pi)
				if d > m_pi then a0, a1 = b.angle, a.angle; d = 2 * m_pi - d end
				Viz.arc(gx, gy, r - lw / 2, r + lw / 2, a0, a0 + d, c, alpha)
			else
				line(x1, y1, x2, y2, lw, c, alpha)
			end
		end
	end

	-- Nodes
	for _, node in ipairs(atlas.list) do
		if node.x and node.type ~= "root" and node.type ~= "mastery" then
			local sx, sy = toScreen(node.x, node.y)
			if sx > -80 and sy > top - 80 and sx < vw + 80 and sy < viewPort.height + 80 then
				local isAlloc = self.alloc[node.id]
				local canAlloc = not isAlloc and (preview[node.id] or false)
				local t = node.type
				if t == "start" then
					self:DrawSprite("startNode", "AtlasPassiveSkillScreenStart", sx, sy, z, 1)
				else
					local iconKey = (t == "keystone" and "keystone" or t == "notable" and "notable" or t == "wormhole" and "wormhole" or "normal") .. (isAlloc and "Active" or "Inactive")
					local frame
					if t == "keystone" then frame = isAlloc and "KeystoneFrameAllocated" or canAlloc and "KeystoneFrameCanAllocate" or "KeystoneFrameUnallocated"
					elseif t == "notable" then frame = isAlloc and "NotableFrameAllocated" or canAlloc and "NotableFrameCanAllocate" or "NotableFrameUnallocated"
					elseif t == "wormhole" then frame = isAlloc and "WormholeFrameAllocated" or canAlloc and "WormholeFrameCanAllocate" or "WormholeFrameUnallocated"
					else frame = isAlloc and "PSSkillFrameActive" or canAlloc and "PSSkillFrameHighlighted" or "PSSkillFrame" end
					local iconName = t == "wormhole" and "Wormhole" or node.icon
					if not self:DrawSprite(iconKey, iconName, sx, sy, z, 1) then
						Viz.arc(sx, sy, 0, 30 * z, 0, m_pi * 2, isAlloc and GOLD or DIM_LINE)
					end
					self:DrawSprite("frame", frame, sx, sy, z, 1)
					if removing[node.id] then Viz.arc(sx, sy, 34 * z, 44 * z, 0, m_pi * 2, col.bad, 0.9) end
				end
				if search and node.searchText:find(search, 1, true) then
					local r = (t == "keystone" and 80 or t == "notable" and 64 or 48) * z
					Viz.arc(sx, sy, r, r + m_max(3, 8 * z), 0, m_pi * 2, col.accent, 0.95)
				end
			end
		end
	end

	-- Header bar: points and hints
	Viz.rect(0, 0, viewPort.width, top, col.bar or { 0.075, 0.085, 0.11 })
	local used = self:PointsUsed()
	local pvCount = 0
	for _ in pairs(preview) do pvCount = pvCount + 1 end
	local ptsText = string.format("Atlas passives: %d / %d", used, atlas.points)
	if pvCount > 0 then ptsText = ptsText .. Viz.hex(PATH) .. string.format("  (+%d)", pvCount) end
	Viz.text(viewPort.width - 12, 10, "RIGHT", 16, "VAR BOLD", ptsText, used > atlas.points and col.bad or col.text)
	Viz.text(viewPort.width - 12, viewPort.height - 20, "RIGHT", 13, "VAR", "Atlas " .. atlas.version:gsub("_", ".") .. "  |  drag to move, wheel to zoom, click to allocate / remove", col.muted)
	if self.flash and GetTime() < self.flash.until_ then
		Viz.text(vw / 2, top + 10, "CENTER", 16, "VAR BOLD", self.flash.text, self.flash.bad and col.bad or col.good)
	end
	SetDrawColor(1, 1, 1)
	SetViewport()

	-- Tooltip
	local n = self.hoverNode
	if n and inside then
		local tt = self.tooltip
		tt:Clear()
		local nameCol = n.type == "keystone" and "^xE8C35A" or n.type == "notable" and "^xD9B45A" or "^7"
		tt:AddLine(18, nameCol .. (n.name ~= "" and n.name or "Atlas start"))
		if n.type == "keystone" then tt:AddLine(13, "^8Keystone") elseif n.type == "notable" then tt:AddLine(13, "^8Notable") elseif n.type == "wormhole" then tt:AddLine(13, "^8Gateway") end
		tt:AddSeparator(10)
		for _, s in ipairs(n.stats) do tt:AddLine(15, "^x8888FF" .. s) end
		for _, r in ipairs(n.reminder) do tt:AddLine(13, "^8" .. r) end
		tt:AddSeparator(10)
		if self.alloc[n.id] then
			local cnt = 0
			for _ in pairs(removing) do cnt = cnt + 1 end
			tt:AddLine(14, n.type == "start" and "^8Starting point" or string.format("^xF55454Click to remove%s", cnt > 1 and (" (" .. cnt .. " passives)") or ""))
		elseif pvCount > 0 then
			tt:AddLine(14, string.format("^x6C8FD9Click to allocate (%d point%s)", pvCount, pvCount == 1 and "" or "s"))
		else
			tt:AddLine(14, "^8Not reachable")
		end
		local sx, sy = toScreen(n.x, n.y)
		SetDrawLayer(nil, 100)
		tt:Draw(viewPort.x + sx - 20, viewPort.y + sy - 20, 40, 40, main.viewPort)
		SetDrawLayer(nil, 0)
	end

	self:DrawControls(viewPort)
end

return AtlasTabClass
