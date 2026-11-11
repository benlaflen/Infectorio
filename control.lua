local AMBIENT = 1 / 20000
local SPREAD = 1 / 60
local LATENT = 15 * 60
local LAUNCH = 1 / 3
local BINS = 60
local CELL_BINS = 300
local ROOT = 256
local SNAP = 0.001
local ENTITY_ABSORPTION = {}
local TILE = {}
local ENTITY = {}
local EMIT = 0.25
local STEP = 0.1
local DECAY = 0.05
local RAY_BOOST = 1.5
local DEFAULT_ABSORPTION = 0.3
local TERM = 0.4
local PENALTY = 0.2
local BONUS = 0.2
local OFFSET = 0.25
local SPAN = 5
local PLANET_PROPERTY = "infection-sterility"
local CURE = "infection-cure"
local ZERO_DAY = "infection-zero-day"
local SPORE_EMIT = 0.01
local SPORE_SWEEP = 600
local DECAY_RATE = 0.001
local DECAY_CAP = 0.25
local PACK_DOSE = 0.05
local current_speed = 1
local SPORE_HOLDERS = {
  "item-entity", "container", "logistic-container", "infinity-container", "linked-container",
  "assembling-machine", "furnace", "lab", "inserter", "transport-belt", "underground-belt", "splitter",
  "loader", "loader-1x1", "cargo-wagon", "car", "spider-vehicle", "character", "rocket-silo",
  "space-platform-hub", "cargo-landing-pad", "cargo-pod", "construction-robot", "logistic-robot", "agricultural-tower",
}
local ENERGY_SOURCES = {"electric_energy_source_prototype", "burner_prototype", "fluid_energy_source_prototype", "heat_energy_source_prototype"}
local TURRETS = {["ammo-turret"] = true, ["electric-turret"] = true, ["fluid-turret"] = true, ["artillery-turret"] = true}

local function root_key(rx, ry) return (rx + 32768) * 65536 + (ry + 32768) end
local function leaf_key(x, y) return (x + 1048576) * 2097152 + (y + 1048576) end
local function leaf_xy(k) return math.floor(k / 2097152) - 1048576, k % 2097152 - 1048576 end

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- largest value in a per-pollutant dictionary, sign = -1 reads absorption instead of emission
local function peak(dict, sign)
  local m = 0
  for _, v in pairs(dict) do m = math.max(m, sign * v) end
  return m
end

local function build_tables()
  TILE, ENTITY = {}, {}

  local top = 0
  for _, p in pairs(prototypes.tile) do top = math.max(top, peak(p.absorptions_per_second, 1)) end
  local decade = top > 0 and math.floor(math.log10(top)) or 0
  local raw, raw_max = {}, 0
  for name, p in pairs(prototypes.tile) do
    local a = peak(p.absorptions_per_second, 1)
    local level = a > 0 and clamp(math.floor(math.log10(a)) - (decade - SPAN), 0, SPAN) or 0
    raw[name] = (SPAN - level) / math.max(p.walking_speed_modifier, 0.05)
    raw_max = math.max(raw_max, raw[name])
  end
  for name, v in pairs(raw) do TILE[name] = TERM * v / raw_max end

  local damage_types = 0
  for _ in pairs(prototypes.damage) do damage_types = damage_types + 1 end
  local stats = {}
  local health_lo, health_hi, emit_hi, absorb_hi, resist_hi = math.huge, 0, 0, 0, 0
  for name, p in pairs(prototypes.entity) do
    local health = p.get_max_health()
    if health > 0 then
      -- per minute
      local emit = peak(p.emissions_per_second, 1) * 60
      for _, source in pairs(ENERGY_SOURCES) do
        local prototype = p[source]
        if prototype then
          local ok, usage = pcall(p.get_max_energy_usage, p)
          if ok then emit = emit + peak(prototype.emissions_per_joule, 1) * usage * 3600 end
        end
      end
      local absorb = peak(p.emissions_per_second, -1) * 60
      local resist = 0
      for _, r in pairs(p.resistances or {}) do resist = resist + r.percent end
      resist = resist / damage_types
      emit_hi, absorb_hi, resist_hi = math.max(emit_hi, emit), math.max(absorb_hi, absorb), math.max(resist_hi, resist)
      if p.type == "tree" or p.count_as_rock_for_filtered_deconstruction or p.is_building then
        local l = math.log(health) / math.log(2)
        stats[name] = {l = l, emit = emit, absorb = absorb, resist = resist}
        health_lo, health_hi = math.min(health_lo, l), math.max(health_hi, l)
      end
    end
  end

  -- how many octaves below the highest value, over SPAN octaves, as 0..1
  local function scale(x, hi)
    return x > 0 and clamp(1 + math.log(x / hi) / math.log(2) / SPAN, 0, 1) or 0
  end
  for name, st in pairs(stats) do
    local base = TERM * (health_hi - st.l) / (health_hi - health_lo)
    local resist = resist_hi > 0 and st.resist / resist_hi or 0
    ENTITY[name] = clamp(base - PENALTY * scale(st.emit, emit_hi) - PENALTY * scale(st.absorb, absorb_hi) + BONUS * resist, 0, TERM)
  end
end

local function reveal(force)
  for name in pairs(prototypes.technology) do
    if name:sub(1, 10) == "infection-" and name ~= CURE then force.technologies[name].enabled = true end
  end
  force.technologies[ZERO_DAY].researched = true
end

local function unlock()
  if storage.revealed then return end
  storage.revealed = true
  for _, force in pairs(game.forces) do reveal(force) end
end

local function init()
  build_tables()
  storage.sterility = {}
  storage.cleaned = storage.cleaned or {}
  storage.spored_cur = storage.spored_cur or {}
  storage.spored_prev = storage.spored_prev or {}
  storage.sweep = storage.sweep or {si = {}, k = {}, i = 1, per_tick = 0}
  if not storage.chunks then
    storage.chunks = {}
    for _, surface in pairs(game.surfaces) do
      local set = {}
      for chunk in surface.get_chunks() do set[leaf_key(chunk.x, chunk.y)] = true end
      storage.chunks[surface.index] = set
    end
  end
  storage.latent = storage.latent or {}
  storage.potent = storage.potent or {}
  storage.health = storage.health or {}
  storage.timer = storage.timer or {}
  storage.bin = storage.bin or {}
  storage.bins = storage.bins or {}
  for b = 1, BINS do storage.bins[b] = storage.bins[b] or {} end
  storage.next_bin = storage.next_bin or 1
  storage.surface_of = storage.surface_of or {}
  storage.count = storage.count or {}
  storage.hijacked = storage.hijacked or {}
  storage.grid = storage.grid or {}
  storage.cells = storage.cells or {}
  storage.cell_bins = storage.cell_bins or {}
  for b = 1, CELL_BINS do storage.cell_bins[b] = storage.cell_bins[b] or {} end
  storage.next_cell_bin = storage.next_cell_bin or 1
  storage.renders = storage.renders or {}
  storage.overlay = storage.overlay or {}
  for key in pairs(storage.latent) do storage.timer[key] = storage.timer[key] or LATENT end
  for _, group in pairs{storage.latent, storage.potent} do
    for key, entity in pairs(group) do
      if not storage.surface_of[key] and entity.valid then
        local index = entity.surface.index
        storage.surface_of[key] = index
        storage.count[index] = (storage.count[index] or 0) + 1
      end
    end
  end
  if not game.forces.infection then game.create_force("infection") end
  if storage.revealed then
    for _, force in pairs(game.forces) do reveal(force) end
  end
  if not storage.active then
    for _, force in pairs(game.forces) do
      local tech = force.technologies["chemical-science-pack"]
      if tech and tech.researched then storage.active = true end
    end
  end
end

script.on_init(init)
script.on_configuration_changed(init)
script.on_load(build_tables)

-- fewest infections, then not targeted by another hijacked platform, then shortest flight
local function target_planet(platform)
  local force = platform.force
  local dist = {}
  if platform.space_location then
    dist[platform.space_location.name] = 0
  elseif platform.space_connection then
    local c = platform.space_connection
    local d = platform.distance or 0
    dist[c.from.name] = d * c.length
    dist[c.to.name] = (1 - d) * c.length
  end
  local visited = {}
  while true do
    local node, nd
    for name, v in pairs(dist) do
      if not visited[name] and (not nd or v < nd) then node, nd = name, v end
    end
    if not node then break end
    visited[node] = true
    for _, c in pairs(prototypes.space_connection) do
      local other = (c.from.name == node and c.to.name) or (c.to.name == node and c.from.name)
      if other and not visited[other] and force.is_space_location_unlocked(other) then
        local alt = nd + c.length
        if not dist[other] or alt < dist[other] then dist[other] = alt end
      end
    end
  end

  local claimed = {}
  for index, name in pairs(storage.hijacked) do
    if index ~= platform.index and force.platforms[index] then claimed[name] = true end
  end

  local best, bc, bcl, bd
  for name, d in pairs(dist) do
    local planet = game.planets[name]
    if planet and planet.surface then
      local c = storage.count[planet.surface.index] or 0
      local cl = claimed[name] and 1 or 0
      if not best or c < bc or (c == bc and (cl < bcl or (cl == bcl and d < bd))) then
        best, bc, bcl, bd = name, c, cl, d
      end
    end
  end
  return best
end

local function infect(entity)
  local key = script.register_on_object_destroyed(entity)
  if storage.latent[key] or storage.potent[key] then return false end
  local index = entity.surface.index
  storage.latent[key] = entity
  storage.health[key] = entity.health
  storage.timer[key] = LATENT * settings.global["infection-latent-multiplier"].value
  storage.surface_of[key] = index
  storage.count[index] = (storage.count[index] or 0) + 1
  storage.bin[key] = storage.next_bin
  storage.bins[storage.next_bin][key] = true
  storage.next_bin = storage.next_bin % BINS + 1
  entity.minable_flag = false

  if entity.type == "unit" or entity.type == "spider-unit" then
    local target = entity.surface.find_nearest_enemy{position = entity.position, max_distance = 3000, force = entity.force}
    if target then
      entity.commandable.set_command{type = defines.command.attack_area, destination = target.position, radius = 32, distraction = defines.distraction.by_anything}
    end
  elseif entity.type == "space-platform-hub" then
    local platform = entity.surface.platform
    if platform then
      storage.hijacked[platform.index] = target_planet(platform)
      for _, e in pairs(entity.surface.find_entities_filtered{force = entity.force}) do e.minable_flag = false end
    end
  end
  return true
end

local function manifest(key, entity)
  storage.latent[key] = nil
  storage.timer[key] = nil
  storage.potent[key] = entity
  if TURRETS[entity.type] then entity.force = "infection" end
end

local function forget(key)
  local b = storage.bin[key]
  if b then storage.bins[b][key] = nil end
  local index = storage.surface_of[key]
  if index and storage.count[index] then storage.count[index] = storage.count[index] - 1 end
  storage.latent[key] = nil
  storage.potent[key] = nil
  storage.health[key] = nil
  storage.timer[key] = nil
  storage.bin[key] = nil
  storage.surface_of[key] = nil
end

local function infected(key)
  return storage.latent[key] or storage.potent[key]
end


-- deepest existing node containing tile (x, y); nil node means an all-clear root
local function lookup(si, x, y)
  local rx, ry = math.floor(x / ROOT), math.floor(y / ROOT)
  local ox, oy, size = rx * ROOT, ry * ROOT, ROOT
  local grid = storage.grid[si]
  local node = grid and grid[root_key(rx, ry)]
  if not node then return nil, ox, oy, size end
  while node.c do
    size = size / 4
    local cx, cy = math.floor((x - ox) / size), math.floor((y - oy) / size)
    ox, oy = ox + cx * size, oy + cy * size
    node = node.c[cy * 4 + cx + 1]
  end
  return node, ox, oy, size
end

local function overlay_players()
  local list = {}
  for index in pairs(storage.overlay) do list[#list + 1] = index end
  return list
end

local function undraw(node)
  if not node.r then return end
  for _, o in pairs(node.r) do
    if o.valid then
      storage.renders[o.id] = nil
      o.destroy()
    end
  end
  node.r = nil
end

local function draw(si, node, ox, oy, size)
  if node.c or node.v <= 0 then undraw(node) return end
  local a = 0.1 + node.v * 0.4
  local color = {r = a, g = a * 0.2, b = 0, a = a}
  if node.r then
    for _, o in pairs(node.r) do if o.valid then o.color = color end end
    return
  end
  local players = overlay_players()
  node.r = {}
  for _, mode in pairs{"game", "chart"} do
    local o = rendering.draw_rectangle{
      color = color, filled = true, left_top = {ox, oy}, right_bottom = {ox + size, oy + size},
      surface = si, render_mode = mode, players = players, visible = #players > 0,
    }
    node.r[#node.r + 1] = o
    storage.renders[o.id] = o
  end
end

local function split(si, node, ox, oy, size)
  local cs = size / 4
  node.c = {}
  for i = 0, 15 do
    local child = {v = node.v}
    node.c[i + 1] = child
    draw(si, child, ox + (i % 4) * cs, oy + math.floor(i / 4) * cs, cs)
  end
  undraw(node)
end

local function activate(si, x, y)
  local cells = storage.cells[si]
  if not cells then cells = {} storage.cells[si] = cells end
  local k = leaf_key(x, y)
  if cells[k] then return end
  local b = storage.next_cell_bin
  cells[k] = b
  local bin = storage.cell_bins[b]
  bin[si] = bin[si] or {}
  bin[si][k] = true
  storage.next_cell_bin = b % CELL_BINS + 1
end

local function deactivate(si, x, y)
  local cells = storage.cells[si]
  local k = leaf_key(x, y)
  local b = cells and cells[k]
  if not b then return end
  cells[k] = nil
  local bin = storage.cell_bins[b][si]
  if bin then bin[k] = nil end
end

local function all_infected(si, ox, oy, size)
  for _, e in pairs(game.surfaces[si].find_entities_filtered{area = {{ox, oy}, {ox + size, oy + size}}}) do
    if e.is_entity_with_health and not infected(script.register_on_object_destroyed(e)) then return false end
  end
  return true
end

-- the only writer of cell values: splits down to the leaf, then re-averages and merges back up
local function set_leaf(si, x, y, v)
  if v < SNAP then v = 0 elseif v > 1 - SNAP then v = 1 end
  local grid = storage.grid[si]
  if not grid then grid = {} storage.grid[si] = grid end
  local rx, ry = math.floor(x / ROOT), math.floor(y / ROOT)
  local rk = root_key(rx, ry)
  local node = grid[rk]
  if not node then
    if v == 0 then return end
    node = {v = 0}
    grid[rk] = node
  end
  local ox, oy, size = rx * ROOT, ry * ROOT, ROOT
  local path = {}
  while size > 1 do
    if not node.c then
      if v == 0 and node.v == 0 then return end
      split(si, node, ox, oy, size)
    end
    path[#path + 1] = {node, ox, oy, size}
    size = size / 4
    local cx, cy = math.floor((x - ox) / size), math.floor((y - oy) / size)
    ox, oy = ox + cx * size, oy + cy * size
    node = node.c[cy * 4 + cx + 1]
  end
  node.v = v
  draw(si, node, x, y, 1)
  if v > 0 then activate(si, x, y) else deactivate(si, x, y) end

  local mergeable = true
  for i = #path, 1, -1 do
    local p, pox, poy, psize = path[i][1], path[i][2], path[i][3], path[i][4]
    local first, sum, uniform = p.c[1].v, 0, mergeable
    for _, child in ipairs(p.c) do
      sum = sum + child.v
      if child.c or child.v ~= first then uniform = false end
    end
    p.v = sum / 16
    if uniform and (first == 0 or (first == 1 and all_infected(si, pox, poy, psize))) then
      for j, child in ipairs(p.c) do
        undraw(child)
        if psize == 4 then deactivate(si, pox + (j - 1) % 4, poy + math.floor((j - 1) / 4)) end
      end
      p.c = nil
      p.v = first
      draw(si, p, pox, poy, psize)
    else
      mergeable = false
    end
  end
  local root = grid[rk]
  if not root.c and root.v == 0 then
    undraw(root)
    grid[rk] = nil
  end
end

local function remaining(entry)
  return entry.v - DECAY_RATE * current_speed * (game.tick - entry.tick) / 60
end

-- static part is cached per tile; invalidated when the building or tile changes
local function sterility(si, surface, x, y)
  local cache = storage.sterility[si]
  if not cache then cache = {} storage.sterility[si] = cache end
  local k = leaf_key(x, y)
  local v = cache[k]
  if not v then
    local tile = TILE[surface.get_tile(x, y).name] or 0
    local building
    for _, e in pairs(surface.find_entities_filtered{area = {{x, y}, {x + 1, y + 1}}}) do
      building = ENTITY[e.name]
      if building then break end
    end
    v = tile + (building or tile * 0.5) + surface.get_property(PLANET_PROPERTY) - OFFSET
    cache[k] = v
  end
  local entry = storage.cleaned[si] and storage.cleaned[si][k]
  return clamp(v + (entry and clamp(remaining(entry), 0, DECAY_CAP) or 0), 0, 1)
end

local function invalidate(entity)
  local cache = storage.sterility[entity.surface.index]
  if not cache then return end
  local box = entity.bounding_box
  for x = math.floor(box.left_top.x), math.floor(box.right_bottom.x) do
    for y = math.floor(box.left_top.y), math.floor(box.right_bottom.y) do
      cache[leaf_key(x, y)] = nil
    end
  end
end

local function cast(si, surface, x, y, angle, value)
  local dx, dy = math.cos(angle), math.sin(angle)
  value = value * RAY_BOOST
  local function exit(ox, oy, size)
    local tx = dx > 0 and (ox + size - x) / dx or dx < 0 and (ox - x) / dx or math.huge
    local ty = dy > 0 and (oy + size - y) / dy or dy < 0 and (oy - y) / dy or math.huge
    return math.min(tx, ty) + 1e-6
  end

  -- the origin tile is free
  local t = exit(math.floor(x), math.floor(y), 1)
  x, y = x + dx * t, y + dy * t
  local node, ox, oy, size

  for _ = 1, 100 do
    if value <= 0 then return end
    local tx, ty = math.floor(x), math.floor(y)
    node, ox, oy, size = lookup(si, tx, ty)
    if node and node.v == 1 and size > 1 then
      t = exit(ox, oy, size)
      value = value - t * STEP
    else
      value = value - sterility(si, surface, tx, ty)
      if value <= 0 then return end
      local absorb = STEP
      for _, e in pairs(surface.find_entities_filtered{area = {{tx, ty}, {tx + 1, ty + 1}}}) do
        if e.is_entity_with_health then absorb = absorb + (ENTITY_ABSORPTION[e.name] or DEFAULT_ABSORPTION) end
      end
      local v = node and node.v or 0
      local inc = math.min(absorb, 1 - v, value)
      if inc > 0 then
        set_leaf(si, tx, ty, v + inc)
        value = value - inc
      end
      value = value - STEP
      t = exit(tx, ty, 1)
    end
    x, y = x + dx * t, y + dy * t
  end
end

-- a build or removal inside an all-infected cell breaks it down so the tile is ticked again
local function touch(entity)
  local pos = entity.position
  local si = entity.surface.index
  local x, y = math.floor(pos.x), math.floor(pos.y)
  local node = lookup(si, x, y)
  if node and node.v == 1 then set_leaf(si, x, y, 1) end
end

local function describe(entity)
  local key = script.register_on_object_destroyed(entity)
  local pos = entity.position
  local node, _, _, size = lookup(entity.surface.index, math.floor(pos.x), math.floor(pos.y))
  local cell = string.format("cell %.3f (%dx%d), sterility %.3f", node and node.v or 0, size, size,
    sterility(entity.surface.index, entity.surface, math.floor(pos.x), math.floor(pos.y)))
  if storage.latent[key] then return string.format("Latent, mean %ds to manifest, %s", math.floor(storage.timer[key] / settings.global["infection-speed-multiplier"].value), cell) end
  if storage.potent[key] then return "Potent, " .. cell end
  return "Not infected, " .. cell
end

local function update_hover(player)
  local frame = player.gui.left.infection_hover
  if not storage.overlay[player.index] then
    if frame then frame.destroy() end
    return
  end
  if not frame then
    frame = player.gui.left.add{type = "frame", name = "infection_hover", caption = "Infection"}
    frame.add{type = "label", name = "infection_text"}
  end
  local e = player.selected
  frame.infection_text.caption = (e and e.valid) and (e.name .. ": " .. describe(e)) or "Nothing selected"
end

local function infect_random()
  local surfaces = {}
  for _, surface in pairs(game.surfaces) do surfaces[#surfaces + 1] = surface end

  -- new strains start next to something artificial or alive
  if not next(storage.latent) and not next(storage.potent) then
    local radius = settings.global["infection-spread-radius"].value
    while #surfaces > 0 do
      local i = math.random(#surfaces)
      local surface = surfaces[i]
      local anchors = {}
      local player = game.forces.player
      for _, e in pairs(surface.find_entities_filtered{force = "player"}) do anchors[#anchors + 1] = e end
      for _, e in pairs(surface.find_entities_filtered{type = {"unit", "spider-unit"}}) do
        local p = e.position
        if player.is_chunk_charted(surface, {math.floor(p.x / 32), math.floor(p.y / 32)}) then anchors[#anchors + 1] = e end
      end
      if #anchors > 0 then
        local anchor = anchors[math.random(#anchors)]
        local candidates = {}
        for _, e in pairs(surface.find_entities_filtered{position = anchor.position, radius = radius}) do
          if e.is_entity_with_health then candidates[#candidates + 1] = e end
        end
        if #candidates > 0 then
          local entity = candidates[math.random(#candidates)]
          if infect(entity) then unlock() return entity end
        end
      end
      table.remove(surfaces, i)
    end
    return
  end

  local player = game.forces.player
  -- retries because most random chunks are empty
  for _ = 1, 20 do
    local surface = surfaces[math.random(#surfaces)]
    local chunk = surface.get_random_chunk()
    if chunk and player.is_chunk_charted(surface, chunk) then
      local x, y = chunk.x * 32, chunk.y * 32
      local candidates = {}
      for _, entity in pairs(surface.find_entities_filtered{area = {{x, y}, {x + 32, y + 32}}}) do
        if entity.is_entity_with_health then candidates[#candidates + 1] = entity end
      end
      if #candidates > 0 then
        local entity = candidates[math.random(#candidates)]
        if infect(entity) then unlock() return entity end
      end
    end
  end
end

script.on_event(defines.events.on_research_finished, function(event)
  if event.research.name == "chemical-science-pack" then storage.active = true end
end)

script.on_event(defines.events.on_tick, function(event)
  local s = settings.global
  local speed = s["infection-speed-multiplier"].value
  current_speed = speed
  local b = event.tick % BINS + 1

  if b == 1 and storage.active and math.random() < AMBIENT * s["infection-ambient-multiplier"].value * speed then
    infect_random()
  end

  if b == 1 then
    for index in pairs(storage.overlay) do
      local player = game.get_player(index)
      if player then update_hover(player) end
    end
  end

  local sweep = storage.sweep
  if event.tick % SPORE_SWEEP == 0 then
    storage.spored_prev, storage.spored_cur = storage.spored_cur, {}
    for _, t in pairs(storage.cleaned) do
      for k, e in pairs(t) do
        if remaining(e) <= 0 then t[k] = nil end
      end
    end
    sweep.si, sweep.k, sweep.i = {}, {}, 1
    for si, set in pairs(storage.chunks) do
      for k in pairs(set) do
        sweep.si[#sweep.si + 1] = si
        sweep.k[#sweep.k + 1] = k
      end
    end
    sweep.per_tick = math.ceil(#sweep.k / SPORE_SWEEP)
  end
  for _ = 1, sweep.per_tick do
    local i = sweep.i
    if i > #sweep.k then break end
    sweep.i = i + 1
    local si = sweep.si[i]
    local surface = game.surfaces[si]
    if surface then
      local cx, cy = leaf_xy(sweep.k[i])
      local found = {}
      for _, e in pairs(surface.find_entities_filtered{area = {{cx * 32, cy * 32}, {cx * 32 + 32, cy * 32 + 32}}, type = SPORE_HOLDERS}) do
        local n = e.type == "item-entity" and (e.stack.name == "infection" and e.stack.count or 0) or e.get_item_count("infection")
        if n > 0 then
          local k = leaf_key(math.floor(e.position.x), math.floor(e.position.y))
          found[k] = (found[k] or 0) + n
        end
      end
      for k, n in pairs(found) do
        local flags = storage.spored_cur[si]
        if not flags then flags = {} storage.spored_cur[si] = flags end
        flags[k] = true
        local x, y = leaf_xy(k)
        local node = lookup(si, x, y)
        local v = node and node.v or 0
        if v < 1 then set_leaf(si, x, y, math.min(1, v + SPORE_EMIT * n * speed)) end
      end
    end
  end

  local cell_bin = storage.cell_bins[event.tick % CELL_BINS + 1]
  if next(cell_bin) then
    local snapshot = {}
    for si, keys in pairs(cell_bin) do
      for k in pairs(keys) do snapshot[#snapshot + 1] = {si, k} end
    end
    for _, item in ipairs(snapshot) do
      local si, k = item[1], item[2]
      local cells = storage.cells[si]
      if cells and cells[k] then
        local x, y = leaf_xy(k)
        local surface = game.surfaces[si]
        local node, _, _, size = lookup(si, x, y)
        if not (surface and node and size == 1) then
          deactivate(si, x, y)
        else
          local v = node.v
          local sc, sp = storage.spored_cur[si], storage.spored_prev[si]
          local has, all = (sc and sc[k]) or (sp and sp[k]) or false, true
          for _, e in pairs(surface.find_entities_filtered{area = {{x, y}, {x + 1, y + 1}}}) do
            if e.is_entity_with_health then
              if infected(script.register_on_object_destroyed(e)) then
                has = true
              elseif math.random() < speed * (1.1 * v - (ENTITY_ABSORPTION[e.name] or DEFAULT_ABSORPTION)) / 2 then
                infect(e)
                has = true
              else
                all = false
              end
            end
          end
          -- decay only when nothing in the surrounding 4x4 block is infected, so empty ground inside the zone holds at 1
          if not has and v > 0 then
            local bx, by = x - x % 4, y - y % 4
            for _, e in pairs(surface.find_entities_filtered{area = {{bx, by}, {bx + 4, by + 4}}}) do
              if e.is_entity_with_health and infected(script.register_on_object_destroyed(e)) then
                has = true
                break
              end
            end
          end
          if not has then
            set_leaf(si, x, y, v - DECAY * speed)
          elseif v == 1 and all then
            set_leaf(si, x, y, 1)
          end
        end
      end
    end
  end

  local bin = storage.bins[b]
  if not next(bin) then return end
  -- snapshot so infections/deaths during the pass can't mutate what we're iterating
  local keys = {}
  for key in pairs(bin) do keys[#keys + 1] = key end

  local spread_p = SPREAD * s["infection-spread-multiplier"].value * speed
  local damage = s["infection-damage"].value * speed

  for _, key in ipairs(keys) do
    local entity = storage.latent[key] or storage.potent[key]
    if entity and not entity.valid then
      forget(key)
    elseif entity then
      if math.random() < spread_p then
        local pos = entity.position
        local si = entity.surface.index
        local x, y = math.floor(pos.x), math.floor(pos.y)
        local node = lookup(si, x, y)
        local v = node and node.v or 0
        if v < 1 then
          v = math.min(1, v + EMIT)
          set_leaf(si, x, y, v)
        end
        cast(si, entity.surface, pos.x, pos.y, math.random() * 2 * math.pi, v)
      end

      -- timer is the mean latent period in seconds
      if storage.latent[key] and math.random() < speed / storage.timer[key] then manifest(key, entity) end

      entity.health = math.min(entity.health, storage.health[key])

      if entity.type == "space-platform-hub" then
        local platform = entity.surface.platform
        if platform then
          local target = target_planet(platform)
          storage.hijacked[platform.index] = target
          if target then
            local schedule = platform.schedule
            local record = schedule and schedule.records and schedule.records[schedule.current]
            if not record or record.station ~= target or #schedule.records ~= 1 then
              platform.schedule = {current = 1, records = {{station = target, wait_conditions = {}}}}
            end
            platform.paused = false
          end
        end
      end

      if storage.potent[key] then
        if entity.type == "rocket-silo" and entity.rocket_silo_status == defines.rocket_silo_status.rocket_ready then
          local planet = entity.surface.planet
          local best, best_n
          -- no platform in orbit: wait for the next one to arrive
          if planet then
            for _, platform in pairs(entity.force.platforms) do
              if platform.valid and platform.hub and platform.hub.valid
                and platform.space_location and platform.space_location.name == planet.name then
                local n = storage.count[platform.surface.index] or 0
                if not best_n or n < best_n then best, best_n = platform, n end
              end
            end
          end
          if best then
            entity.launch_rocket{type = defines.cargo_destination.station, station = best.hub}
          end
        elseif entity.type == "space-platform-hub" then
          local location = entity.surface.platform and entity.surface.platform.space_location
          local planet = location and game.planets[location.name]
          local target = planet and planet.surface
          if target then
            local inventory = entity.get_inventory(defines.inventory.hub_main)
            for i = 1, #inventory do
              local stack = inventory[i]
              if stack.valid_for_read then
                local pod = entity.create_cargo_pod()
                if pod then
                  pod.get_inventory(defines.inventory.cargo_unit).insert{name = stack.name, quality = stack.quality.name, count = 1}
                  if stack.count == 1 then stack.clear() else stack.count = stack.count - 1 end
                  pod.cargo_pod_destination = {type = defines.cargo_destination.surface, surface = target}
                end
                break
              end
            end
          end
        end

        local before = entity.health
        entity.damage(damage, "neutral", "infection")
        -- hubs and landing pads ignore damage()
        if entity.valid and damage > 0 and entity.health >= before then
          if before > damage then
            entity.health = before - damage
          else
            entity.surface.spill_item_stack{position = entity.position, stack = {name = "infection", count = 1}}
            if not entity.die("neutral") then entity.destroy() end
          end
        end
      end

      if entity.valid then storage.health[key] = entity.health end
    end
  end
end)

script.on_event(defines.events.on_entity_died, function(event)
  local entity = event.entity
  local key = script.register_on_object_destroyed(entity)
  invalidate(entity)
  if not infected(key) then touch(entity) return end
  forget(key)
  if event.damage_type and event.damage_type.name == "infection" then
    entity.surface.spill_item_stack{position = entity.position, stack = {name = "infection", count = 1}}
  end
  local si = entity.surface.index
  local pos = entity.position
  set_leaf(si, math.floor(pos.x), math.floor(pos.y), 1)
  for i = 0, 7 do cast(si, entity.surface, pos.x, pos.y, i * math.pi / 4, 1) end
end)

script.on_event({
  defines.events.on_built_entity,
  defines.events.on_robot_built_entity,
  defines.events.on_space_platform_built_entity,
  defines.events.script_raised_built,
  defines.events.script_raised_revive,
  defines.events.on_player_mined_entity,
  defines.events.on_robot_mined_entity,
  defines.events.on_space_platform_mined_entity,
  defines.events.script_raised_destroy,
}, function(event)
  if event.entity and event.entity.valid then
    invalidate(event.entity)
    touch(event.entity)
  end
end)

script.on_event({
  defines.events.on_player_built_tile,
  defines.events.on_robot_built_tile,
  defines.events.on_space_platform_built_tile,
  defines.events.on_player_mined_tile,
  defines.events.on_robot_mined_tile,
  defines.events.on_space_platform_mined_tile,
  defines.events.script_raised_set_tiles,
}, function(event)
  local cache = storage.sterility[event.surface_index]
  if not cache then return end
  for _, t in pairs(event.tiles) do
    cache[leaf_key(math.floor(t.position.x), math.floor(t.position.y))] = nil
  end
end)

script.on_event("infection-apply", function(event)
  local player = game.get_player(event.player_index)
  local stack = player.cursor_stack
  local entity = player.selected
  if not (stack and stack.valid_for_read and stack.name == "infection-sterilization-pack"
      and entity and entity.valid and player.can_reach_entity(entity)) then return end
  local si = entity.surface.index
  local t = storage.cleaned[si]
  if not t then t = {} storage.cleaned[si] = t end
  local box = entity.bounding_box
  local keys, top = {}, 0
  for x = math.floor(box.left_top.x), math.floor(box.right_bottom.x) do
    for y = math.floor(box.left_top.y), math.floor(box.right_bottom.y) do
      local k = leaf_key(x, y)
      keys[#keys + 1] = k
      if t[k] then top = math.max(top, clamp(remaining(t[k]), 0, DECAY_CAP)) end
    end
  end
  local applied = math.min(PACK_DOSE, DECAY_CAP - top, stack.durability)
  if applied <= 0 then return end
  for _, k in pairs(keys) do
    t[k] = {v = math.min(DECAY_CAP, (t[k] and clamp(remaining(t[k]), 0, DECAY_CAP) or 0) + applied), tick = game.tick}
  end
  stack.drain_durability(applied)
end)

script.on_event(defines.events.on_chunk_generated, function(event)
  local si = event.surface.index
  local set = storage.chunks[si]
  if not set then set = {} storage.chunks[si] = set end
  set[leaf_key(event.position.x, event.position.y)] = true
end)

script.on_event(defines.events.on_chunk_deleted, function(event)
  local set = storage.chunks[event.surface_index]
  if not set then return end
  for _, p in pairs(event.positions) do set[leaf_key(p.x, p.y)] = nil end
end)

script.on_event(defines.events.on_surface_deleted, function(event)
  local si = event.surface_index
  storage.chunks[si] = nil
  storage.cleaned[si] = nil
  storage.spored_cur[si] = nil
  storage.spored_prev[si] = nil
  storage.grid[si] = nil
  storage.cells[si] = nil
  storage.sterility[si] = nil
  storage.count[si] = nil
  for _, bin in pairs(storage.cell_bins) do bin[si] = nil end
end)

script.on_event(defines.events.on_object_destroyed, function(event)
  forget(event.registration_number)
end)

script.on_event(defines.events.on_rocket_launch_ordered, function(event)
  local silo = event.rocket_silo
  if not (silo and silo.valid) then return end
  local key = script.register_on_object_destroyed(silo)
  if not (storage.latent[key] or storage.potent[key]) then return end
  if math.random() >= LAUNCH * settings.global["infection-launch-multiplier"].value then return end
  local pod = event.rocket and event.rocket.valid and event.rocket.attached_cargo_pod
  if pod and pod.valid and pod.is_entity_with_health then infect(pod) end
end)

script.on_event(defines.events.on_force_created, function(event)
  if storage.revealed then reveal(event.force) end
end)

script.on_event(defines.events.on_cargo_pod_finished_ascending, function(event)
  local pod = event.cargo_pod
  if not (pod and pod.valid) then return end
  local destination = pod.cargo_pod_destination
  local hub = destination and destination.type == defines.cargo_destination.station and destination.station
  if not (hub and hub.valid and hub.type == "space-platform-hub") then return end
  local inventory = pod.get_inventory(defines.inventory.cargo_unit)
  if not (inventory and inventory.get_item_count("atomic-bomb") > 0) then return end
  hub.die()
end)

local function selected(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if not player or not player.admin then return end
  local entity = player.selected
  if not entity then player.print("Nothing selected") return end
  return player, entity, script.register_on_object_destroyed(entity)
end

commands.add_command("infect-random", "Infect a random entity on a random surface.", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if player and not player.admin then return end
  local entity = infect_random()
  local msg = entity
    and string.format("Infected %s [gps=%d,%d,%s]", entity.name, math.floor(entity.position.x), math.floor(entity.position.y), entity.surface.name)
    or "No entity found"
  if player then player.print(msg) else game.print(msg) end
end)

commands.add_command("infect-selected", "Infect the hovered entity.", function(cmd)
  local player, entity = selected(cmd)
  if not entity then return end
  if not entity.is_entity_with_health then player.print("Not infectable") return end
  player.print(infect(entity) and "Infected" or "Already infected")
end)

commands.add_command("manifest-selected", "Make the hovered entity potent.", function(cmd)
  local player, entity, key = selected(cmd)
  if not entity then return end
  if storage.latent[key] then manifest(key, entity) player.print("Manifested")
  elseif storage.potent[key] then player.print("Already potent")
  else player.print("Not infected") end
end)

commands.add_command("inspect-selected", "Show infection state of the hovered entity and its cell.", function(cmd)
  local player, entity = selected(cmd)
  if entity then player.print(describe(entity)) end
end)

script.on_event(defines.events.on_selected_entity_changed, function(event)
  if storage.overlay[event.player_index] then update_hover(game.get_player(event.player_index)) end
end)

commands.add_command("infection-overlay", "Toggle the infection cell overlay (world and map).", function(cmd)
  local player = cmd.player_index and game.get_player(cmd.player_index)
  if not player or not player.admin then return end
  storage.overlay[player.index] = (not storage.overlay[player.index]) or nil
  local players = overlay_players()
  for id, o in pairs(storage.renders) do
    if o.valid then
      o.players = players
      o.visible = #players > 0
    else
      storage.renders[id] = nil
    end
  end
  update_hover(player)
  player.print(storage.overlay[player.index] and "Overlay on" or "Overlay off")
end)