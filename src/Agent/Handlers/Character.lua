-- Agent Edition character import (Stage 2): feed a character downloaded from
-- pathofexile.com into PoB's own importer (Classes/ImportTab.lua), and report
-- a compact state of the build for progress tracking.
--
-- agent-mcp downloads the public character data (it owns the rate limits); this
-- file never makes network requests, so it works the same in the live window and
-- in the headless runner.
-- Loaded by Tools.lua with (handlers, Ops, helpers).
local handlers, Ops, h = ...

local t_insert = table.insert

local function strip(text)
	return (tostring(text or ''):gsub('%^x%x%x%x%x%x%x', ''):gsub('%^%d', ''))
end

-- What a character looks like for progress tracking: level, stats, items, gems, passives.
local function characterState()
	local spec = build.spec
	local state = {
		name = build.buildName,
		level = tonumber(build.characterLevel),
		className = spec.curClassName,
		ascendancy = spec.curAscendClassName,
		mainSkill = h.mainSkillName(),
		stats = h.keyStats(),
		assumptions = h.assumptions(),
		characterHash = build.importTab and build.importTab.lastCharacterHash or nil,
		items = {}, gems = {}, nodes = {}, named = {},
	}
	-- Items: one entry per equipped slot, with a fingerprint of the mods so a
	-- re-crafted item with the same name still shows up as changed.
	for _, it in ipairs(Ops.get_items() or {}) do
		local item = it.id and it.id > 0 and build.itemsTab.items[it.id]
		if item and (it.shown ~= false or it.slot:match('^Jewel')) and not it.slot:find('Swap') then
			local mods = {}
			for _, list in ipairs({ item.enchantModLines, item.implicitModLines, item.explicitModLines, item.crucibleModLines }) do
				for _, line in ipairs(list or {}) do if line.line then t_insert(mods, strip(line.line)) end end
			end
			local slot = it.slot
			local socket = tonumber(slot:match('^Jewel (%d+)$'))
			if socket then slot = spec.allocNodes[socket] and ('Jewel socket ' .. socket) or nil end
			if slot then
				t_insert(state.items, {
					slot = slot,
					name = strip(item.title or item.name),
					base = item.baseName,
					rarity = item.rarity,
					mods = common.sha1(table.concat(mods, '\n')):sub(1, 12),
				})
			end
		end
	end
	-- Gems: every gem in every socket group.
	local skills = Ops.get_skills()
	for _, g in ipairs(skills and skills.groups or {}) do
		for _, gem in ipairs(g.gems or {}) do
			if gem.name ~= '' then
				t_insert(state.gems, { name = gem.name, level = gem.level, quality = gem.quality, support = gem.isSupport, slot = g.slot, enabled = gem.enabled and g.enabled ~= false })
			end
		end
	end
	-- Passives: allocated node ids; names for the ones worth naming.
	for id, node in pairs(spec.allocNodes) do
		if type(id) == 'number' and id < 65536 then
			t_insert(state.nodes, id)
			if node.type == 'Keystone' or node.type == 'Notable' or node.ascendancyName then
				if not node.isAscendancyStart and node.type ~= 'ClassStart' then
					state.named[tostring(id)] = (node.ascendancyName and (node.ascendancyName .. ': ') or '') .. (node.dn or node.name or '?')
				end
			elseif node.type == 'Mastery' then
				local effect = spec.tree.masteryEffects and spec.tree.masteryEffects[spec.masterySelections[id]]
				state.named[tostring(id)] = (node.dn or node.name or 'Mastery') .. ': ' .. (effect and table.concat(effect.sd or {}, ' / ') or '?')
			end
		end
	end
	table.sort(state.nodes)
	state.pointsUsed = (spec:CountAllocNodes())
	return state
end

handlers.character_state = function()
	local output, err = h.mainOutput()
	if not output then return { ok = false, error = err } end
	return { ok = true, state = characterState() }
end

-- params: {
--   character = entry from character-window/get-characters (name, league, class, level, ...),
--   items     = body of character-window/get-items,
--   passives  = body of character-window/get-passive-skills,
--   realm     = "pc" | "xbox" | "sony", accountHash = sha1 of the account name (optional),
--   name      = build name to set (optional),
-- }
-- Replaces items, skills and tree like PoB's Import tab with every "Delete" box
-- ticked; the build's configuration is kept (PoB's importer still sets bandit,
-- pantheon and the resistance penalty from the character, as it always does).
handlers.character_import = function(params)
	if not build or not build.importTab then return { ok = false, error = 'no build open in PoB' } end
	local char, items, passives = params.character, params.items, params.passives
	if type(char) ~= 'table' or type(char.name) ~= 'string' or type(char.class) ~= 'string' then
		return { ok = false, error = 'character (name, class, league, level) is required' }
	end
	if type(items) ~= 'table' or type(items.items) ~= 'table' then return { ok = false, error = 'items (get-items response) is required' } end
	if type(passives) ~= 'table' or type(passives.hashes) ~= 'table' then return { ok = false, error = 'passives (get-passive-skills response) is required' } end
	local tab = build.importTab
	local input = build.configTab.input
	-- The game does not say which auras are switched on, so the importer turns
	-- every gem on. Skill gems the player switched off in this build (gem or its
	-- group) stay off after the sync.
	local keepOff = {}
	for _, g in ipairs(build.skillsTab.socketGroupList or {}) do
		for _, gem in ipairs(g.gemList or {}) do
			local gd = gem.gemData
			if gd and gd.name and not (gd.grantedEffect and gd.grantedEffect.support) and (gem.enabled == false or g.enabled == false) then
				keepOff[gd.name] = true
			end
		end
	end
	local ok, err = pcall(function()
		-- Same shape PoB builds from the account-name endpoints (ImportTab:DownloadPassiveTree/DownloadItems).
		local base = {}
		for k, v in pairs(char) do base[k] = v end
		base.league = base.league or 'Standard'
		local treeData = copyTable(base)
		passives.bandit_choice = passives.bandit_choice or input.bandit
		passives.pantheon_major = passives.pantheon_major or input.pantheonMajorGod
		passives.pantheon_minor = passives.pantheon_minor or input.pantheonMinorGod
		treeData.passives = passives
		treeData.jewels = passives.items
		tab:ImportPassiveTreeAndJewels(treeData, true)
		local itemData = copyTable(base)
		itemData.equipment = items.items
		itemData.guardian = items.guardian
		tab:ImportItemsAndSkills(itemData, true, true, false)
	end)
	if not ok then return { ok = false, error = 'PoB could not import the character: ' .. tostring(err) } end
	local keptOff, seen = {}, {}
	for _, g in ipairs(build.skillsTab.socketGroupList or {}) do
		for _, gem in ipairs(g.gemList or {}) do
			local gd = gem.gemData
			if gd and gd.name and keepOff[gd.name] and not (gd.grantedEffect and gd.grantedEffect.support) then
				gem.enabled = false
				if not seen[gd.name] then seen[gd.name] = true t_insert(keptOff, gd.name) end
			end
		end
	end
	tab.lastCharacterHash = common.sha1(char.name)
	tab.lastLeague = char.league
	tab.lastRealm = (params.realm and tostring(params.realm):upper()) or tab.lastRealm
	if type(params.accountHash) == 'string' then tab.lastAccountHash = params.accountHash end
	if type(params.name) == 'string' and params.name ~= '' then build.buildName = params.name end
	build.modFlag = true
	build.buildFlag = true
	local output, outErr = h.mainOutput()
	if not output then return { ok = false, error = outErr } end
	return { ok = true, state = characterState(), keptOff = keptOff }
end
