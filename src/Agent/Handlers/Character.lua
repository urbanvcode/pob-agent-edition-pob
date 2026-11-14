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

-- Fight settings (Configuration tab) and which skill gems are switched on: what
-- a sync compares with another build of the same character, or with the last
-- sync. Keys PoB's importer sets from the character itself are left out.
local IMPORTER_SET = { bandit = true, pantheonMajorGod = true, pantheonMinorGod = true, resistancePenalty = true, buildName = true }

local function fightSettings()
	local tab = build.configTab
	local config = {}
	for k, v in pairs(tab.input or {}) do
		local tv = type(v)
		if not IMPORTER_SET[k] and (tv == 'boolean' or tv == 'number' or tv == 'string') and v ~= tab:GetDefaultState(k, tv) then
			config[k] = v
		end
	end
	-- Active skill gems by name: true when any copy is switched on (gem and its group).
	local gems = {}
	for _, g in ipairs(build.skillsTab.socketGroupList or {}) do
		for _, gem in ipairs(g.gemList or {}) do
			local gd = gem.gemData
			if gd and gd.name and not (gd.grantedEffect and gd.grantedEffect.support) then
				gems[gd.name] = gems[gd.name] == true or (gem.enabled ~= false and g.enabled ~= false)
			end
		end
	end
	return config, gems
end

handlers.config_profile = function()
	if not build or not build.configTab then return { ok = false, error = 'no build open in PoB' } end
	h.mainOutput()
	local config, gems = fightSettings()
	return { ok = true, config = config, gems = gems, mainSkill = h.mainSkillName(),
		className = build.spec.curClassName, ascendancy = build.spec.curAscendClassName }
end

local configVars
local function configVar(key)
	if configVars == nil then
		configVars = {}
		local okLoad, list = pcall(LoadModule, 'Modules/ConfigOptions')
		for _, var in ipairs(okLoad and type(list) == 'table' and list or {}) do
			if var.var and not configVars[var.var] then configVars[var.var] = var end
		end
	end
	return configVars[key]
end

local function showValue(key, v)
	if v == nil then
		-- Not set: PoB's default for that option (off, 0 or the list's first choice).
		local var = configVar(key)
		local hint = var and (var.type == 'check' and 'boolean' or var.type == 'list' and 'string' or 'number') or 'string'
		v = build.configTab:GetDefaultState(key, hint)
		if v == nil or v == '' then return 'default' end
	end
	local label = Ops.config_value_label and Ops.config_value_label(key, v)
	if label then return strip(label) end
	if v == true then return 'on' elseif v == false then return 'off' end
	return tostring(v)
end

-- params: { config = {key = value}, gems = {name = on} } from config_profile of
-- another build (or the last sync). Lists what differs in the open build and
-- simulates the open build with those settings (rolled back, nothing changes).
-- Returns the differences, the edit ops that copy them, and stats before/after.
handlers.config_effect = function(params)
	if not build or not build.configTab then return { ok = false, error = 'no build open in PoB' } end
	h.mainOutput()
	local tab = build.configTab
	local other = type(params.config) == 'table' and params.config or {}
	local otherGems = type(params.gems) == 'table' and params.gems or {}
	local mine, myGems = fightSettings()
	local keys = {}
	for k in pairs(other) do if not IMPORTER_SET[k] then keys[k] = true end end
	for k in pairs(mine) do keys[k] = true end
	local diffs, values = {}, {}
	for k in pairs(keys) do
		local ov, mv = other[k], mine[k]
		if ov ~= mv and configVar(k) then
			local var = configVar(k)
			local target = ov
			if target == nil then target = tab:GetDefaultState(k, type(mv)) end
			values[k] = target
			t_insert(diffs, { key = k, label = strip(var.label or k):gsub(':$', ''), now = showValue(k, mv), other = showValue(k, ov) })
		end
	end
	table.sort(diffs, function(a, b) return a.key < b.key end)
	local ops = {}
	if next(values) then t_insert(ops, { op = 'config', values = values }) end
	local gemDiffs, seen = {}, {}
	for gi, g in ipairs(build.skillsTab.socketGroupList or {}) do
		for ji, gem in ipairs(g.gemList or {}) do
			local gd = gem.gemData
			local name = gd and gd.name
			local want = name and otherGems[name]
			if want ~= nil and not (gd.grantedEffect and gd.grantedEffect.support) then
				local on = gem.enabled ~= false and g.enabled ~= false
				if want ~= on then
					if want and g.enabled == false then t_insert(ops, { op = 'group_enabled', group = gi, enabled = true }) end
					if want and gem.enabled == false or not want then t_insert(ops, { op = 'gem', group = gi, gem = ji, enabled = want }) end
					if not seen[name] then seen[name] = true t_insert(gemDiffs, { name = name, now = on, other = want }) end
				end
			end
		end
	end
	if #ops == 0 then return { ok = true, diffs = diffs, gems = gemDiffs, ops = ops } end
	local res = handlers.what_if({ ops = ops })
	if not res or not res.ok then return { ok = false, error = res and res.error or 'what_if failed' } end
	return { ok = true, diffs = diffs, gems = gemDiffs, ops = ops, before = res.before, after = res.after, rolledBack = res.rolledBack }
end
