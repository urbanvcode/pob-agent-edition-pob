-- PoB Agent Edition: the AI chat panel (Stage 10), docked on the right of the build
-- screen. Build.lua gives it the right edge: open, it takes Panel.width() pixels;
-- hidden, only a small "AI" tab on the right edge stays to open it again.
-- Replies stream in from Agent/Chat.lua. Markup the AI writes (agent-mcp/src/chat/backends.ts):
--   [[node:Name]] [[item:Name]] [[gem:Name]]   links that highlight in PoB (hover: tooltip)
--   [[apply:Label|{"ops":[...]}]]              a card: Preview (what_if, rolled back), then Apply
--   **bold**, "- " lists, "# " headings

local Viz = LoadModule("Agent/Viz")
local col = Viz.col
local dkjson = require("dkjson")
local m_max, m_min, m_floor = math.max, math.min, math.floor
local t_insert = table.insert

main.agentChat = main.agentChat or LoadModule("Agent/Chat")
local Chat = main.agentChat
Chat.registerLive()

local Panel = { }
local WIDTH, TAB_W, TAB_H = 430, 22, 86
local HEADER_H, INPUT_H = 60, 58
local FONT, SIZE, LINE = "VAR", 14, 18
local LINK_COL = { gem = { 0.40, 0.80, 0.98 }, node = { 0.98, 0.84, 0.40 }, item = { 0.75, 0.62, 0.98 } }

local host = new("ControlHost")
local controls = host.controls
local state = { scroll = 0, atBottom = true, revision = -1, width = 0, rows = { }, height = 0, cards = { }, build = nil }

function Panel.isOpen()
	local open = Chat.settings().open
	return open == nil and true or open == true
end
function Panel.width() return Panel.isOpen() and WIDTH or 0 end
local function setOpen(v) Chat.setSetting("open", v) end

-- Text clean-up: the PoB font has no curly quotes, dashes, bullets or ellipsis, and ^ starts a colour code.
local REPLACE = { ["\226\128\156"] = '"', ["\226\128\157"] = '"', ["\226\128\152"] = "'", ["\226\128\153"] = "'",
	["\226\128\147"] = "-", ["\226\128\148"] = "-", ["\226\128\166"] = "...", ["\226\128\162"] = "-", ["\226\134\146"] = "->",
	["\195\151"] = "x", ["\226\137\136"] = "~", ["\226\137\165"] = ">=", ["\226\137\164"] = "<=", ["\194\160"] = " " }
local function clean(s)
	s = tostring(s or ""):gsub("%^", "")
	for k, v in pairs(REPLACE) do s = s:gsub(k, v) end
	return s
end

-- Link actions ----------------------------------------------------------------------
local function findNode(build, name)
	local lname = name:lower()
	for _, node in pairs(build.spec.nodes) do
		if node.dn and node.dn:lower() == lname then return node end
	end
end
local function findItem(build, name)
	local lname = name:lower()
	for _, item in pairs(build.itemsTab.items) do
		local n = (item.name or ""):lower()
		if n == lname or (item.title and item.title:lower() == lname) or (item.baseName and n:find(lname, 1, true)) then return item end
	end
end
local function findGroup(build, name)
	local lname = name:lower()
	for _, group in ipairs(build.skillsTab.socketGroupList) do
		for _, gem in ipairs(group.gemList or { }) do
			local gname = (gem.grantedEffect and gem.grantedEffect.name) or gem.nameSpec or ""
			if gname:lower() == lname or (gem.nameSpec or ""):lower() == lname then return group end
		end
	end
end

local function openLink(build, kind, name)
	if kind == "node" then
		build.viewMode = "TREE"
		local search = build.treeTab.controls.treeSearch
		if search then search:SetText(name, true) end
	elseif kind == "item" then
		build.viewMode = "ITEMS"
		local item = findItem(build, name)
		local list = build.itemsTab.controls.itemList
		if item and list and list.list then
			local idx = isValueInArray(list.list, item.id)
			if idx then list:SelectIndex(idx) end
		end
	elseif kind == "gem" then
		build.viewMode = "SKILLS"
		local group = findGroup(build, name)
		if group then build.skillsTab:SetDisplayGroup(group) end
	end
end

local tooltip = new("Tooltip")
local function linkTooltip(build, kind, name)
	tooltip:Clear()
	if kind == "item" then
		local item = findItem(build, name)
		if item then build.itemsTab:AddItemTooltip(tooltip, item, nil, true) return true end
	elseif kind == "node" then
		local node = findNode(build, name)
		if node then
			tooltip:AddLine(16, "^7" .. node.dn .. (build.spec.allocNodes[node.id] and " ^x4FD1C2(allocated)" or ""))
			for _, line in ipairs(node.sd or { }) do tooltip:AddLine(14, "^x8888FF" .. line) end
			tooltip:AddLine(14, "^8Click: find it on the tree")
			return true
		end
	elseif kind == "gem" then
		local group = findGroup(build, name)
		tooltip:AddLine(16, "^7" .. name)
		tooltip:AddLine(14, group and ("^8In: " .. (group.displayLabel or group.label or "a socket group") .. ". Click: open in Skills") or "^8Not in this build")
		return true
	end
	tooltip:AddLine(14, "^8" .. name .. " (not found in this build)")
	return true
end

-- Layout: messages -> rows of styled segments ------------------------------------------
-- A row: { y, h, segs = { {x, text, color, font, link={kind,name}} }, card = cardIndex, bg = role }
local function measure(text, font) return DrawStringWidth(SIZE, font or FONT, text) end

local function inlineTokens(line, baseCol)
	-- Split into tokens: words (with trailing space), links and bold runs.
	local tokens, bold, pos = { }, false, 1
	while pos <= #line do
		local ls, le, kind, name = line:find("%[%[(%a+):([^%]|]+)%]%]", pos)
		local bs = line:find("**", pos, true)
		local nextStop = m_min(ls or #line + 1, bs or #line + 1)
		local chunk = line:sub(pos, nextStop - 1)
		-- A space right after a bold run or link belongs to the token before it.
		if chunk:match("^%s") and tokens[#tokens] and not tokens[#tokens].text:match(" $") then tokens[#tokens].text = tokens[#tokens].text .. " " end
		for word, space in chunk:gmatch("(%S+)(%s*)") do
			t_insert(tokens, { text = word .. (space ~= "" and " " or ""), color = bold and col.text or baseCol, font = bold and "VAR BOLD" or FONT })
		end
		if nextStop > #line then break end
		if ls and ls == nextStop then
			kind = kind:lower()
			local after = line:sub(le + 1, le + 1)
			t_insert(tokens, { text = clean(name) .. ((after == " ") and " " or ""), color = LINK_COL[kind] or col.accent, font = FONT, link = { kind = kind, name = name } })
			pos = le + 1
			if after == " " then pos = pos + 1 end
		else
			bold = not bold
			pos = bs + 2
		end
	end
	return tokens
end

local function layout(build, width)
	local rows, cards, y = { }, { }, 6
	local textW = width - 28
	local function addRows(text, baseCol, indent, role)
		for rawLine in (text .. "\n"):gmatch("(.-)\n") do
			local line = rawLine:gsub("%s+$", "")
			local applyLabel, applyJson = line:match("%[%[apply:([^|%]]+)|(.-)%]%]")
			if applyLabel then
				local ok, data = pcall(dkjson.decode, applyJson)
				local ops = ok and type(data) == "table" and (data.ops or (data[1] and data)) or nil
				t_insert(cards, { label = clean(applyLabel), ops = ops, bad = not ops })
				t_insert(rows, { y = y, h = 54, card = #cards, role = role })
				y = y + 60
			elseif line == "" then
				y = y + 8
			else
				local x0, lineCol, font = indent, baseCol, FONT
				local bullet = line:match("^%s*[-*] ")
				local heading = line:match("^#+%s")
				local numbered = line:match("^%s*%d+[.)] ")
				if heading then line = line:gsub("^#+%s*", "") lineCol = col.accent end
				local segs, x = { }, x0
				local hang = x0
				if bullet then
					t_insert(segs, { x = x0, text = "-", color = col.muted, font = FONT })
					line = line:gsub("^%s*[-*] ", "")
					x, hang = x0 + 14, x0 + 14
				elseif numbered then
					hang = x0 + measure(numbered)
				end
				local tokens = inlineTokens(clean(line), lineCol)
				if heading then for _, tk in ipairs(tokens) do if not tk.link then tk.font = "VAR BOLD" end end end
				for _, tk in ipairs(tokens) do
					local w = measure(tk.text, tk.font)
					if x + w > textW and x > hang then
						t_insert(rows, { y = y, h = LINE, segs = segs, role = role })
						y = y + LINE
						segs, x = { }, hang
					end
					t_insert(segs, { x = x, text = tk.text, color = tk.color, font = tk.font, link = tk.link, w = w })
					x = x + w
				end
				t_insert(rows, { y = y, h = LINE, segs = segs, role = role })
				y = y + LINE
			end
		end
	end
	for i, m in ipairs(Chat.messages) do
		local startY, startRow = y, #rows + 1
		if m.role == "user" then
			addRows(m.text or "", col.text, 10, "user")
		else
			local tools = m.tools or { }
			if #tools > 0 then
				local names, seen = { }, { }
				for _, tl in ipairs(tools) do
					if not seen[tl.name] then seen[tl.name] = true t_insert(names, tl.name .. (tl.ok == false and " (failed)" or "")) end
				end
				addRows("PoB tools: " .. table.concat(names, ", "), col.muted, 10, "tools")
			end
			if (m.text or "") ~= "" then addRows(m.text, Viz.mix(col.text, col.muted, 0.1), 10, "ai") end
			if m.pending then addRows((m.activity and m.activity ~= "" and m.activity or "thinking") .. "...", col.muted, 10, "status") end
			if m.cancelled then addRows("(stopped)", col.muted, 10, "status") end
			if m.error then addRows(m.error, col.bad, 10, "error") end
		end
		-- The background goes before the message rows so it is drawn under them.
		t_insert(rows, startRow, { y = startY - 3, h = y - startY + 4, bg = m.role, msg = i, behind = true })
		y = y + 10
	end
	return rows, cards, y
end

-- Deltas for a preview / apply result ------------------------------------------------------
local DELTA_KEYS = {
	{ "CombinedDPS", "DPS" }, { "TotalEHP", "EHP" }, { "Life", "Life" }, { "EnergyShield", "ES" },
	{ "FireResist", "Fire res" }, { "ColdResist", "Cold res" }, { "LightningResist", "Light res" }, { "ChaosResist", "Chaos res" },
	{ "PhysicalMaximumHitTaken", "Phys max hit" }, { "Speed", "Speed" }, { "ManaUnreserved", "Mana free" },
}
local function deltaText(res)
	if type(res) ~= "table" then return "No result." end
	if res.ok == false then return "Failed: " .. tostring(res.error) end
	if (res.failed or 0) > 0 then
		for _, r in ipairs(res.results or { }) do if not r.ok then return "Failed: " .. tostring(r.error) end end
	end
	local parts = { }
	local b, a = res.before or { }, res.after or { }
	for _, kv in ipairs(DELTA_KEYS) do
		local x, y = tonumber(b[kv[1]]), tonumber(a[kv[1]])
		if x and y and math.abs(y - x) > math.max(math.abs(x) * 0.001, 0.01) then
			local s
			if kv[1]:match("Resist$") then s = string.format("%s %+d", kv[2], m_floor(y - x + 0.5))
			elseif x ~= 0 then s = string.format("%s %+.1f%%", kv[2], (y - x) / math.abs(x) * 100)
			else s = string.format("%s %s", kv[2], Viz.num(y)) end
			t_insert(parts, s)
		end
		if #parts >= 5 then break end
	end
	return #parts > 0 and table.concat(parts, ", ") or "No calculated stat changes."
end

-- Controls ---------------------------------------------------------------------------------
local function backendIndex()
	local b = Chat.settings().backend
	for i, e in ipairs(Chat.BACKENDS) do if e.value == b then return i end end
	return 1
end
local function sendInput()
	local text = controls.input.buf
	if state.build and Chat.send(state.build, text) then
		controls.input:SetText("")
		state.atBottom = true
	end
end

controls.input = new("EditControl", nil, { 0, 0, 300, 22 }, "", nil, "%c", 2000)
controls.input:SetPlaceholder("Ask about this build...")
controls.input.enterFunc = sendInput
controls.send = new("ButtonControl", nil, { 0, 0, 56, 22 }, "Send", sendInput)
controls.send.shown = function() return not Chat.busy end
controls.send.enabled = function() return controls.input.buf:match("%S") ~= nil end
controls.stop = new("ButtonControl", nil, { 0, 0, 56, 22 }, "^xF05555Stop", function() Chat.cancel() end)
controls.stop.shown = function() return Chat.busy end
controls.stop.tooltipText = "Stop the answer (ends the backend and its tools)."
controls.newChat = new("ButtonControl", nil, { 0, 0, 74, 20 }, "New chat", function() Chat.newChat() end)
controls.newChat.tooltipText = "Start a new conversation for this build (the old one is cleared)."
controls.hide = new("ButtonControl", nil, { 0, 0, 22, 20 }, ">", function() setOpen(false) end)
controls.hide.tooltipText = "Hide the chat (the AI tab on the right edge opens it again)."
local labels = { }
for _, e in ipairs(Chat.BACKENDS) do t_insert(labels, e.label) end
controls.backend = new("DropDownControl", nil, { 0, 0, 150, 20 }, labels, function(index)
	Chat.setSetting("backend", Chat.BACKENDS[index].value)
end)
controls.backend.tooltipFunc = function(tip)
	tip:Clear()
	local e = Chat.BACKENDS[backendIndex()]
	tip:AddLine(14, "^7" .. e.desc)
	tip:AddLine(14, "^8More in Options > AI chat (sign in, API key).")
end
controls.backend.enabled = function() return not Chat.busy end
controls.edits = new("CheckBoxControl", nil, { 0, 0, 18 }, "AI may edit:", function(on) Chat.setSetting("allowEdits", on) end)
controls.edits.tooltipText = "Off: the AI only reads and simulates; changes come as Preview / Apply cards you click.\nOn: the AI may change the build in this window when you ask (it never saves over your build file).\nTakes effect with the next message."

-- Backend availability line (from the bridge's --check).
local function backendNote()
	local s = Chat.settings()
	local okAvail, why = Chat.available()
	if not okAvail then return why, col.bad end
	local c = Chat.check
	if not c then return Chat.checking and "Checking backends..." or nil, col.muted end
	if s.backend == "api" then
		if not (c.api and c.api.key) and not Chat.hasApiKey() then return "No API key stored: add it in Options > AI chat.", col.warn end
		return nil
	end
	local b = c[s.backend]
	if not b or not b.found then return Chat.backendLabel() .. " not found. Install it, or pick another backend.", col.warn end
	if b.signedIn == false then return Chat.backendLabel() .. " is not signed in: Options > AI chat > Sign in.", col.warn end
end

-- Drawing -----------------------------------------------------------------------------------
local function drawClosedTab(build, x, y, inputEvents)
	local cx, cy = GetCursorPos()
	local hover = Viz.hover(cx, cy, x, y, TAB_W, TAB_H)
	Viz.rect(x, y, TAB_W, TAB_H, hover and col.cardHi or col.card)
	Viz.rect(x, y, 2, TAB_H, col.accent)
	local label = { "A", "I", "", "C", "h", "a", "t" }
	for i, ch in ipairs(label) do
		if ch ~= "" then Viz.text(x + 7, y + 4 + (i - 1) * 11, "LEFT", 12, "VAR BOLD", ch, Chat.busy and col.warn or col.accent) end
	end
	for i, event in ipairs(inputEvents) do
		if event.type == "KeyDown" and event.key == "LEFTBUTTON" and hover then
			setOpen(true)
			inputEvents[i] = nil
		end
	end
	if hover then
		SetDrawLayer(nil, 10)
		tooltip:Clear()
		tooltip:AddLine(14, "^7Open the AI chat" .. (Chat.busy and " (an answer is coming)" or ""))
		tooltip:Draw(x, y, TAB_W, TAB_H, main.viewPort)
		SetDrawLayer(nil, 0)
	end
end

function Panel.draw(build, inputEvents)
	Chat.load(build)
	state.build = build
	local screenW, screenH = main.screenW, main.screenH
	SetDrawLayer(4)
	if not Panel.isOpen() then
		drawClosedTab(build, screenW - TAB_W, 32 + m_floor((screenH - 32 - TAB_H) / 2), inputEvents)
		SetDrawLayer(0)
		return
	end
	if not Chat.check and not Chat.checking then Chat.refreshCheck() end
	local x, y, w, h = screenW - WIDTH, 32, WIDTH, screenH - 32
	local cx, cy = GetCursorPos()
	local inPanel = Viz.hover(cx, cy, x, y, w, h)

	-- Frame
	Viz.rect(x, y, w, h, col.bg)
	UITheme.set("divider")
	DrawImage(nil, x, y, 4, h)
	local ix, iw = x + 4, w - 4

	-- Header
	Viz.text(ix + 10, y + 6, "LEFT", 16, "VAR BOLD", "AI Chat", col.accent)
	controls.hide.x, controls.hide.y = ix + iw - 30, y + 5
	controls.newChat.x, controls.newChat.y = controls.hide.x - 80, y + 5
	controls.backend.x, controls.backend.y = ix + 10, y + 32
	controls.backend:SelByValue(Chat.BACKENDS[backendIndex()].label)
	controls.edits.x, controls.edits.y = ix + iw - 26, y + 33
	controls.edits.state = Chat.settings().allowEdits
	local note, noteCol = backendNote()

	-- Input area
	local inputY = y + h - INPUT_H
	Viz.rect(ix, inputY, iw, INPUT_H, col.card)
	controls.input.x, controls.input.y, controls.input.width = ix + 8, inputY + 28, iw - 76
	controls.send.x, controls.send.y = ix + iw - 62, inputY + 28
	controls.stop.x, controls.stop.y = controls.send.x, controls.send.y
	local statusText, statusCol
	if Chat.busy then
		local secs = m_floor(((GetTime and GetTime() or 0) - (Chat.startedAt or 0)) / 1000)
		statusText, statusCol = string.format("%s is answering... %ds", Chat.backendLabel(), secs), col.warn
	elseif note then
		statusText, statusCol = note, noteCol
	else
		statusText, statusCol = "Sees the open build, profile and guide. Enter sends.", col.muted
	end
	Viz.text(ix + 10, inputY + 6, "LEFT", 13, "VAR", Viz.fit(13, "VAR", statusText, iw - 20), statusCol)

	-- Messages
	local mx, my, mw, mh = ix, y + HEADER_H, iw, inputY - (y + HEADER_H)
	Viz.rect(mx, my - 2, mw, 1, col.border)
	if state.revision ~= Chat.revision or state.width ~= mw or (Chat.busy and state.frame ~= GetTime()) then
		state.rows, state.cards, state.height = layout(build, mw)
		local cardsOld = state.cardState or { }
		state.cardState = { }
		for i, c in ipairs(state.cards) do
			local key = c.label .. "|" .. i
			state.cardState[i] = cardsOld[i] and cardsOld[i].key == key and cardsOld[i] or { key = key }
		end
		state.revision, state.width = Chat.revision, mw
		if state.atBottom then state.scroll = m_max(0, state.height - mh) end
	end
	state.frame = GetTime and GetTime() or 0
	local maxScroll = m_max(0, state.height - mh)

	local clicked
	for i, event in ipairs(inputEvents) do
		if inPanel and event.type == "KeyUp" and (event.key == "WHEELUP" or event.key == "WHEELDOWN") and cy >= my and cy < my + mh then
			state.scroll = m_min(maxScroll, m_max(0, state.scroll + (event.key == "WHEELUP" and -54 or 54)))
			state.atBottom = state.scroll >= maxScroll - 2
			inputEvents[i] = nil
		elseif inPanel and event.type == "KeyDown" and event.key == "LEFTBUTTON" and cy >= my and cy < my + mh then
			clicked = true
			inputEvents[i] = nil
		end
	end
	state.scroll = m_min(state.scroll, maxScroll)

	SetViewport(mx, my, mw, mh)
	local lx, ly = cx - mx, cy - my + state.scroll
	local hoverLink
	if #Chat.messages == 0 then
		local tx = 14
		Viz.text(tx, 14, "LEFT", 15, "VAR BOLD", "Ask anything about this build", col.text)
		local intro = {
			"The AI uses PoB's own numbers (diagnose, what_if)",
			"on the build in this window, your profile and guide.",
			"Names it mentions are links: click to find them.",
			"Suggested changes get Preview and Apply buttons.",
		}
		for i, l in ipairs(intro) do Viz.text(tx, 18 + i * 18, "LEFT", 13, "VAR", l, col.muted) end
		local qy = 18 + #intro * 18 + 22
		for _, q in ipairs(Chat.QUICK) do
			local qw = measure(q.label) + 20
			local hov = Viz.hover(lx, cy - my, tx, qy, qw, 24)
			Viz.rect(tx, qy, qw, 24, hov and col.cardHi or col.card)
			Viz.rect(tx, qy, 2, 24, col.accent)
			Viz.text(tx + 10, qy + 4, "LEFT", SIZE, FONT, q.label, col.text)
			if hov and clicked and not Chat.busy then
				Chat.send(build, q.text)
				state.atBottom = true
			end
			qy = qy + 30
		end
	end
	for _, row in ipairs(state.rows) do
		local ry = row.y - state.scroll
		if ry + row.h >= 0 and ry <= mh then
			if row.behind then
				if row.bg == "user" then Viz.rect(6, ry, mw - 12, row.h, col.cardHi) Viz.rect(6, ry, 2, row.h, col.accent) end
			elseif row.card then
				local c, cs = state.cards[row.card], state.cardState[row.card]
				Viz.rect(10, ry, mw - 20, row.h, col.card)
				Viz.rect(10, ry, 2, row.h, c.bad and col.bad or col.good)
				Viz.text(20, ry + 5, "LEFT", SIZE, "VAR BOLD", Viz.fit(SIZE, "VAR BOLD", c.label, mw - 50), col.text)
				local resText = c.bad and "This suggestion could not be read." or cs.text or "Preview simulates it in PoB; nothing changes."
				Viz.text(20, ry + 34, "LEFT", 13, "VAR", Viz.fit(13, "VAR", resText, mw - 180), cs.bad and col.bad or (cs.text and col.text or col.muted))
				if not c.bad then
					local buttons = { { "Preview", not cs.applied }, { "Apply", cs.previewed and not cs.applied } }
					local bx = mw - 20 - 2 * 70
					for bi, b in ipairs(buttons) do
						local bxx = bx + (bi - 1) * 70
						local hov = b[2] and Viz.hover(lx, ly, bxx, row.y + 29, 64, 20)
						Viz.rect(bxx, ry + 29, 64, 20, hov and col.cardHi or col.bg)
						Viz.outline(bxx, ry + 29, 64, 20, b[2] and (bi == 2 and col.good or col.border) or col.track)
						Viz.text(bxx + 8, ry + 31, "LEFT", 14, "VAR", b[1], b[2] and col.text or col.muted)
						if hov and clicked then
							if bi == 1 then
								local res = Chat.preview(c.ops)
								cs.text = "Preview: " .. deltaText(res)
								cs.previewed = type(res) == "table" and res.ok ~= false and (res.failed or 0) == 0
								cs.bad = not cs.previewed
							else
								local res = Chat.apply(c.ops)
								local okApply = type(res) == "table" and res.ok ~= false and (res.failed or 0) == 0
								cs.text = okApply and ("Applied (not saved): " .. deltaText(res)) or deltaText(res)
								cs.applied, cs.bad = okApply, not okApply
							end
						end
					end
					if cs.applied then Viz.text(mw - 170, ry + 5, "LEFT", 13, "VAR", "applied - save as a new build", col.good) end
				end
			else
				local rowCol = row.role == "user" and col.text or nil
				for _, s in ipairs(row.segs or { }) do
					local hov = s.link and Viz.hover(lx, ly, s.x, row.y, s.w or 0, row.h)
					Viz.text(s.x, ry, "LEFT", SIZE, s.font or FONT, s.text, rowCol or s.color)
					if s.link then
						Viz.rect(s.x, ry + SIZE + 1, (s.w or 0) - (s.text:sub(-1) == " " and measure(" ") or 0), 1, s.color, hov and 1 or 0.45)
						if hov then
							hoverLink = { s = s, x = mx + s.x, y = my + ry, w = s.w or 0, h = row.h }
							if clicked then openLink(build, s.link.kind, s.link.name) end
						end
					end
				end
			end
		end
	end
	SetViewport()
	-- Scroll bar
	if maxScroll > 0 then
		local barH = m_max(24, mh * mh / state.height)
		local barY = my + (mh - barH) * (state.scroll / maxScroll)
		Viz.rect(mx + mw - 5, my, 3, mh, col.track, 0.6)
		Viz.rect(mx + mw - 5, barY, 3, barH, col.muted)
	end

	host:ProcessControlsInput(inputEvents, main.viewPort)
	-- Keep keystrokes in the chat while its input has focus.
	if host.selControl == controls.input and controls.input.hasFocus then
		for i, event in ipairs(inputEvents) do
			if event.type == "Char" or (event.type == "KeyDown" and not IsKeyDown("CTRL")) then inputEvents[i] = nil end
		end
	end
	-- Clicks anywhere else in the panel must not reach the tab behind it.
	for i, event in ipairs(inputEvents) do
		if inPanel and (event.type == "KeyDown" or event.type == "KeyUp") and event.key:match("BUTTON") then inputEvents[i] = nil end
	end
	host:DrawControls(main.viewPort)

	if hoverLink then
		SetDrawLayer(nil, 20)
		if linkTooltip(build, hoverLink.s.link.kind, hoverLink.s.link.name) then
			tooltip:Draw(hoverLink.x, hoverLink.y, hoverLink.w, hoverLink.h, main.viewPort)
		end
		SetDrawLayer(nil, 0)
	end
	SetDrawLayer(0)
end

-- Exposed for tests.
Panel._layout = layout
Panel._deltaText = deltaText

return Panel
