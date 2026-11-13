-- Agent Edition request handlers, shared by the live window (Agent/LiveServer.lua)
-- and the headless runner (Agent/Headless.lua). agent-mcp calls them by name.
-- Usage: local handlers, BuildOps = loadfile(dir .. 'Core.lua')(dir)
-- Handlers operate on the global `build` (PoB's BUILD mode object).
-- Ported from ianderse/pob-mcp (https://github.com/ianderse/pob-mcp, GPL-3.0), original file: lua/bridge_handlers.lua
-- (Ops.lua is its lua/pob_ops.lua). Tools.lua is new in Agent Edition.
local ADAPTER_DIR = ...
local BuildOps = dofile(ADAPTER_DIR .. 'Ops.lua')

-- Class name → classId mapping (PoE1)
local CLASS_IDS = {
  Scion=0, Marauder=1, Ranger=2, Witch=3, Duelist=4, Templar=5, Shadow=6,
  scion=0, marauder=1, ranger=2, witch=3, duelist=4, templar=5, shadow=6,
}
-- Ascendancy index matches the order in the tree data ascendancies array (1-based)
local ASCENDANCY_IDS = {
  [0] = { Ascendant=1 },
  [1] = { Juggernaut=1, Berserker=2, Chieftain=3 },
  [2] = { Raider=1, Deadeye=2, Pathfinder=3 },
  [3] = { Occultist=1, Elementalist=2, Necromancer=3 },
  [4] = { Slayer=1, Gladiator=2, Champion=3 },
  [5] = { Inquisitor=1, Hierophant=2, Guardian=3 },
  [6] = { Assassin=1, Trickster=2, Saboteur=3 },
}

-- Evaluate upstream PoB's native anoint simulation without altering the loaded build.
-- This follows NotableDBControl's MiscCalculator approach, while restoring the UI
-- selection even if a candidate calculation fails.
local function evaluate_anoint_candidates(params)
  if not build or not build.itemsTab or not build.spec or not build.spec.tree then return { ok = false, error = 'build not initialized' } end
  local slotName = params.slot
  if type(slotName) ~= 'string' or slotName == '' then return { ok = false, error = 'slot is required (for example, Amulet)' } end
  local control = build.itemsTab.slots and build.itemsTab.slots[slotName]
  local item = control and control.selItemId and build.itemsTab.items[control.selItemId] or nil
  if not item then return { ok = false, error = 'no equipped item in ' .. slotName } end
  if slotName ~= 'Amulet' and not item.canBeAnointed then return { ok = false, error = slotName .. ' is not an anointable item slot' } end

  local tab, previousItem, previousEnchantSlot = build.itemsTab, build.itemsTab.displayItem, build.itemsTab.anointEnchantSlot
  local ok, result = pcall(function()
    tab:SetDisplayItem(item)
    tab.anointEnchantSlot = 1
    local calc = build.calcsTab:GetMiscCalculator()
    local repSlotName = item.base and item.base.type or slotName
    local base = calc({ repSlotName = repSlotName, repItem = tab:anointItem(nil) })
    local baseDps = tonumber(base.CombinedDPS or base.TotalDPS or 0) or 0
    local baseEhp = tonumber(base.TotalEHP or 0) or 0
    local candidates, evaluated, skipped = {}, 0, 0
    for id, node in pairs(build.spec.tree.nodes or {}) do
      if node.recipe and node.dn and node.modKey ~= '' and not build.spec.allocNodes[id] then
        local candidateOk, output = pcall(calc, { repSlotName = repSlotName, repItem = tab:anointItem(node) })
        if candidateOk and output then
          local dps = (tonumber(output.CombinedDPS or output.TotalDPS or 0) or 0) - baseDps
          local ehp = (tonumber(output.TotalEHP or 0) or 0) - baseEhp
          local focus = params.focus or 'both'
          local score = focus == 'dps' and dps or (focus == 'defence' and ehp or (dps / math.max(baseDps, 1) + 0.5 * ehp / math.max(baseEhp, 1)))
          local recipe = {}; for _, oil in ipairs(node.recipe or {}) do table.insert(recipe, tostring(oil)) end
          table.insert(candidates, { nodeId = tonumber(id) or id, name = node.dn, dpsDelta = dps, ehpDelta = ehp, score = score, recipe = recipe })
          evaluated = evaluated + 1
        else skipped = skipped + 1 end
      end
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    local limit = math.min(math.max(tonumber(params.limit) or 50, 1), 500)
    while #candidates > limit do table.remove(candidates) end
    return { ok = true, candidates = candidates, base = { CombinedDPS = baseDps, TotalEHP = baseEhp }, evaluated = evaluated, skipped = skipped, slot = slotName, baseType = item.baseName or repSlotName, focus = params.focus or 'both' }
  end)
  tab:SetDisplayItem(previousItem); tab.anointEnchantSlot = previousEnchantSlot
  if not ok then return { ok = false, error = 'anoint evaluation failed: ' .. tostring(result) } end
  return result
end

-- Drive upstream TradeQueryGenerator directly, avoiding its interactive dialog.
-- The generator is a normal PoB class; its coroutine is advanced synchronously
-- here and the generated JSON is returned to Node for the actual Trade API call.
local function generate_weighted_trade_query(params)
  if not build or not build.itemsTab or not build.itemsTab.tradeQuery then return { ok = false, error = 'build/items not initialized' } end
  local slotName = params.slot
  local slot = type(slotName) == 'string' and build.itemsTab.slots and build.itemsTab.slots[slotName] or nil
  if not slot then return { ok = false, error = 'unknown equipment slot: ' .. tostring(slotName) } end
  local options = params.options or {}
  options.includeMirrored = options.includeMirrored == true
  options.includeCorrupted = options.includeCorrupted ~= false
  options.includeScourge = options.includeScourge == true
  options.includeEldritch = options.includeEldritch == true
  options.influence1 = tonumber(options.influence1) or 1
  options.influence2 = tonumber(options.influence2) or 1
  options.jewelType = options.jewelType or 'Any'
  options.statWeights = options.statWeights or build.itemsTab.tradeQuery.statSortSelectionList
  if not options.statWeights or #options.statWeights == 0 then options.statWeights = { { label = 'Full DPS', stat = 'FullDPS', weightMult = 1.0 }, { label = 'Effective Hit Pool', stat = 'TotalEHP', weightMult = 0.5 } } end
  local ok, result = pcall(function()
    local generator = new('TradeQueryGenerator', build.itemsTab.tradeQuery)
    local query, warning
    generator.requesterCallback = function(_, generated, err) query, warning = generated, err end
    generator.requesterContext = {}
    generator.tradeTypeIndex = 2 -- available listings, matching the MCP default
    generator:StartQuery(slot, options)
    local frames = 0
    while generator.calcContext and generator.calcContext.co and frames < 100000 do generator:OnFrame(); frames = frames + 1 end
    if generator.calcContext and generator.calcContext.co then error('TradeQueryGenerator did not complete after 100000 frames') end
    if not query then error(warning or 'PoB generated no trade query') end
    return { ok = true, query = query, warning = warning, frames = frames }
  end)
  if not ok then return { ok = false, error = 'weighted trade query failed: ' .. tostring(result) } end
  return result
end

-- Wrap a BuildOps function that returns (result, err) into the JSON envelope.
-- resultKey names the field the TS bridge reads the payload from.
local function op(fn, resultKey)
  return function(params)
    local res, err = fn(params or {})
    if res == nil then return { ok = false, error = err or 'operation failed' } end
    local envelope = { ok = true }
    if resultKey then envelope[resultKey] = res end
    return envelope
  end
end

local handlers = {}

handlers.ping = function() return { ok = true, pong = true } end

handlers.version = function()
  return { ok = true, version = {
    number = _G.launch and launch.versionNumber or '?',
    branch = _G.launch and launch.versionBranch or '?',
    platform = _G.launch and launch.versionPlatform or '?',
    adapter = 'agent-headless-v1',
  } }
end

handlers.new_build = function(params)
  if not _G.newBuild then return { ok = false, error = 'headless wrapper not initialized' } end
  _G.newBuild()
  if params and (params.className or params.ascendancy) then
    local classId = params.className and (CLASS_IDS[params.className] or CLASS_IDS[params.className:lower()]) or 0
    local ascendId = params.ascendancy and ASCENDANCY_IDS[classId] and ASCENDANCY_IDS[classId][params.ascendancy] or 0
    if build and build.spec then
      BuildOps.import_from_node_list(build.spec, classId, ascendId, 0, {}, {}, {}, nil)
    end
  end
  return { ok = true }
end

handlers.load_build_xml = function(params)
  if not params or type(params.xml) ~= 'string' then return { ok = false, error = 'missing xml' } end
  if not _G.loadBuildFromXML then return { ok = false, error = 'headless wrapper not initialized' } end
  -- Tree packs (Agent/TreePacks.lua): fetch missing trees first, so a failure is a clear error, not a half-loaded build
  local TreePacks = LoadModule('Agent/TreePacks')
  for _, ver in ipairs(TreePacks.MissingInXml(params.xml)) do
    local okTree, treeErr = TreePacks.Download(ver)
    if not okTree then return { ok = false, error = (TreePacks.OfflineMessage(ver, treeErr):gsub('%s*\n%s*', ' ')) } end
  end
  local ok, err = pcall(_G.loadBuildFromXML, params.xml, (params.name and tostring(params.name)) or 'API Build')
  if not ok then return { ok = false, error = tostring(err) } end
  -- PoB can close the build or stop at a conversion popup without throwing.
  -- Shutdown clears savers, so stale build fields alone do not prove a load.
  if not build or not build.savers or not build.spec then
    return { ok = false, error = 'PoB did not initialize the build; check the XML and supported build version' }
  end
  return { ok = true, build_id = 1 }
end

handlers.get_stats = function(params)
  local stats, err = BuildOps.export_stats(params and params.fields or nil)
  if not stats then return { ok = false, error = err } end
  return { ok = true, stats = stats }
end

handlers.set_tree = function(params)
  local ok2, err = BuildOps.set_tree(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true, tree = (BuildOps.get_tree()) }
end

handlers.update_tree_delta = function(params)
  local result, err = BuildOps.update_tree_delta(params or {})
  if not result then return { ok = false, error = err } end
  return { ok = true, tree = result.tree, droppedNodes = result.droppedNodes }
end

handlers.set_config = function(params)
  local result, err = BuildOps.set_config(params or {})
  if not result then return { ok = false, error = err } end
  -- Report per-key outcomes so the caller can tell an applied change from a
  -- rejected one instead of assuming success.
  return {
    ok = true,
    applied = result.applied,
    rejected = result.rejected,
    config = (BuildOps.get_config()),
  }
end

handlers.set_main_selection = function(params)
  local ok2, err = BuildOps.set_main_selection(params or {})
  if not ok2 then return { ok = false, error = err } end
  return { ok = true, skills = (BuildOps.get_skills()) }
end

handlers.set_level = function(params)
  if not params or params.level == nil then return { ok = false, error = 'missing level' } end
  local ok2, err = BuildOps.set_level(params.level)
  if not ok2 then return { ok = false, error = err } end
  return { ok = true }
end

handlers.set_flask_active = op(BuildOps.set_flask_active)
handlers.set_gem_level = op(BuildOps.set_gem_level)
handlers.set_gem_quality = op(BuildOps.set_gem_quality)
handlers.set_gem_enabled = op(BuildOps.set_gem_enabled)
handlers.remove_skill = op(BuildOps.remove_skill)
handlers.remove_gem = op(BuildOps.remove_gem)

handlers.get_tree = op(BuildOps.get_tree, 'tree')
handlers.get_items = op(BuildOps.get_items, 'items')
handlers.get_skills = op(BuildOps.get_skills, 'skills')
handlers.get_build_info = op(BuildOps.get_build_info, 'info')
handlers.get_config = function()
  local cfg, err = BuildOps.get_config()
  if cfg == nil then return { ok = false, error = err or 'operation failed' } end
  return { ok = true, config = cfg, labels = (BuildOps.get_config_labels()) }
end
handlers.calc_with = op(BuildOps.calc_with, 'output')
handlers.export_build_xml = op(BuildOps.export_build_xml, 'xml')
handlers.add_item_text = op(BuildOps.add_item_text, 'item')
handlers.create_socket_group = op(BuildOps.create_socket_group, 'socketGroup')
handlers.add_gem = op(BuildOps.add_gem, 'gem')
handlers.search_nodes = op(BuildOps.search_nodes, 'results')
handlers.get_mastery_options = op(BuildOps.get_mastery_options, 'result')
handlers.get_ailments = op(BuildOps.get_ailments, 'result')
handlers.save_build = op(BuildOps.save_build, 'result')
handlers.list_specs = op(BuildOps.list_specs, 'result')
handlers.select_spec = op(BuildOps.select_spec, 'result')
handlers.create_spec = op(BuildOps.create_spec, 'result')
handlers.delete_spec = op(BuildOps.delete_spec, 'result')
handlers.rename_spec = op(BuildOps.rename_spec, 'result')
handlers.list_item_sets = op(BuildOps.list_item_sets, 'result')
handlers.select_item_set = op(BuildOps.select_item_set, 'result')
handlers.set_socket_group_enabled = op(BuildOps.set_socket_group_enabled, 'result')

-- Test candidate items in a slot without equipping them: returns the build's
-- key stats with each item swapped in, plus the current (base) stats.
-- params: { slot = "Helmet", items = { "<PoB item text>", ... } }
local TEST_FIELDS = {
  'FullDPS', 'CombinedDPS', 'TotalDPS', 'TotalDotDPS', 'TotalEHP', 'Life', 'EnergyShield', 'Mana', 'ManaUnreserved',
  'FireResist', 'ColdResist', 'LightningResist', 'ChaosResist', 'EffectiveSpellSuppressionChance',
  'MissingFireResist', 'MissingColdResist', 'MissingLightningResist', 'MissingChaosResist',
  'EvadeChance', 'BlockChance', 'Armour', 'Evasion', 'PhysicalMaximumHitTaken', 'ChaosMaximumHitTaken',
  'EffectiveMovementSpeedMod', 'Str', 'Dex', 'Int', 'ReqStr', 'ReqDex', 'ReqInt',
}
local function pick(out)
  local r = {}
  for _, k in ipairs(TEST_FIELDS) do
    local v = out and out[k]
    if type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge then r[k] = v end
  end
  return r
end
handlers.test_items = function(params)
  if not build or not build.calcsTab or not build.itemsTab then return { ok = false, error = 'build not initialized' } end
  local slotName = params.slot
  if type(slotName) ~= 'string' or not build.itemsTab.slots[slotName] then return { ok = false, error = 'unknown slot: ' .. tostring(slotName) } end
  if type(params.items) ~= 'table' then return { ok = false, error = 'items must be a list of item texts' } end
  local calcFunc = build.calcsTab:GetMiscCalculator()
  local okBase, base = pcall(calcFunc, {})
  if not okBase then return { ok = false, error = 'base calculation failed: ' .. tostring(base) } end
  local results = {}
  for i, text in ipairs(params.items) do
    local okItem, item = pcall(new, 'Item', text)
    if not okItem or not item or not item.base then
      results[i] = { ok = false, error = 'PoB could not read this item' }
    else
      local okCalc, out = pcall(calcFunc, { repSlotName = slotName, repItem = item })
      if okCalc and type(out) == 'table' then
        results[i] = { ok = true, stats = pick(out), name = item.title or item.name, baseName = item.baseName, rarity = item.rarity }
      else
        results[i] = { ok = false, error = 'calculation failed: ' .. tostring(out) }
      end
    end
  end
  local slot = build.itemsTab.slots[slotName]
  local current = slot.selItemId and slot.selItemId > 0 and build.itemsTab.items[slot.selItemId] or nil
  return { ok = true, result = {
    slot = slotName,
    base = pick(base),
    current = current and { name = current.title or current.name, baseName = current.baseName, rarity = current.rarity } or nil,
    results = results,
  } }
end

-- Atlas passive tree (PoB Agent Edition's Atlas tab) ------------------------
local function atlasNode(n, alloc)
  return { id = n.id, name = n.name, type = n.type, stats = n.stats, allocated = alloc and alloc[n.id] == true or nil }
end
local function atlasTab()
  local tab = build and build.atlasTab
  if not tab then return nil, 'this PoB has no Atlas tab (needs PoB Agent Edition)' end
  local atlas = tab:Data()
  if not atlas then return nil, 'atlas data not available: ' .. tostring(tab.loadError) end
  return tab, atlas
end
handlers.atlas_get = function()
  local tab, atlas = atlasTab()
  if not tab then return { ok = false, error = atlas } end
  local nodes = {}
  for _, n in ipairs(tab:AllocatedList()) do table.insert(nodes, atlasNode(n)) end
  local AtlasData = LoadModule('Agent/AtlasData')
  local summary = AtlasData.summary(atlas, tab.alloc)
  local mechanics, bonuses = {}, {}
  for _, m in ipairs(summary.mechanics) do table.insert(mechanics, { name = m.name, points = m.points }) end
  for _, l in ipairs(summary.stats) do table.insert(bonuses, l.text) end
  return { ok = true, result = { version = atlas.version, pointsUsed = tab:PointsUsed(), pointsTotal = atlas.points, nodes = nodes, mechanics = mechanics, bonuses = bonuses, link = AtlasData.encodeLink(atlas, tab.alloc) } }
end
handlers.atlas_search = function(params)
  local tab, atlas = atlasTab()
  if not tab then return { ok = false, error = atlas } end
  local res = {}
  for _, n in ipairs(tab:Search(params.query or '', tonumber(params.limit) or 25)) do
    local node = atlasNode(n, tab.alloc)
    local path = (not tab.alloc[n.id]) and LoadModule('Agent/AtlasData').pathTo(atlas, tab.alloc, n.id) or nil
    node.pathCost = path and #path or nil
    table.insert(res, node)
  end
  return { ok = true, result = res }
end
-- params: { add = {ids}, remove = {ids}, replace = {ids}, link = "https://..." }
handlers.atlas_edit = function(params)
  local tab, atlas = atlasTab()
  if not tab then return { ok = false, error = atlas } end
  local AtlasData = LoadModule('Agent/AtlasData')
  local report = { added = {}, removed = {}, errors = {} }
  if type(params.link) == 'string' and params.link ~= '' then
    local ids, err = AtlasData.decodeLink(params.link)
    if not ids then return { ok = false, error = err } end
    tab:SetNodes(ids)
  elseif type(params.replace) == 'table' then
    tab:SetNodes(params.replace)
  end
  for _, id in ipairs(type(params.remove) == 'table' and params.remove or {}) do
    for _, r in ipairs(tab:Deallocate(tostring(id))) do table.insert(report.removed, r) end
  end
  for _, id in ipairs(type(params.add) == 'table' and params.add or {}) do
    local path, err = tab:Allocate(tostring(id))
    if path then for _, p in ipairs(path) do table.insert(report.added, p) end
    else table.insert(report.errors, tostring(id) .. ': ' .. tostring(err)) end
  end
  report.pointsUsed = tab:PointsUsed()
  report.pointsTotal = atlas.points
  return { ok = true, result = report }
end

handlers.evaluate_anoint_candidates = evaluate_anoint_candidates
handlers.generate_weighted_trade_query = generate_weighted_trade_query

handlers.get_capabilities = function()
  local actions = { 'quit' }
  for name in pairs(handlers) do table.insert(actions, name) end
  table.sort(actions)
  return { ok = true, capabilities = { mode = 'headless', adapter = 'agent-headless-v1', actions = actions } }
end

-- Agent Edition tools (summary, diagnose, edits, what-if, suggestions)
loadfile(ADAPTER_DIR .. 'Tools.lua')(handlers, BuildOps, op, ADAPTER_DIR)

-- Guide mode (Stage 3): guide stages, guide data, gap to a guide stage
loadfile(ADAPTER_DIR .. 'Guide.lua')(handlers, BuildOps)

-- Levelling coach (Stage 7): act-by-act plan, milestones, checkpoints, next steps
loadfile(ADAPTER_DIR .. 'Levelling.lua')(handlers, BuildOps)

return handlers, BuildOps
