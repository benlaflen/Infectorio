local PROPERTIES = {"pressure", "solar-power", "magnetic-field", "gravity"}
local planets = data.raw.planet

data:extend{{type = "surface-property", name = "infection-sterility", default_value = 0, localised_unit_key = "surface-property-unit.infection-sterility"}}

local scores = {}
for _, name in pairs(PROPERTIES) do
  local prototype = data.raw["surface-property"][name]
  if not prototype then goto continue end
  local default = prototype.default_value
  local values, lo = {}, math.huge
  for planet_name, planet in pairs(planets) do
    local v = planet.surface_properties and planet.surface_properties[name] or default
    values[planet_name] = v
    lo = math.min(lo, v)
  end
  local logs, hi = {}, 0
  for planet_name, v in pairs(values) do
    logs[planet_name] = math.log10(lo > 0 and v / lo or v - lo + 1)
    hi = math.max(hi, logs[planet_name])
  end
  for planet_name, l in pairs(logs) do
    scores[planet_name] = scores[planet_name] or {}
    scores[planet_name][name] = hi > 0 and 0.1 * l / hi or 0
  end
  ::continue::
end

for planet_name, planet in pairs(planets) do
  local s = scores[planet_name]
  local v = 2 * s["solar-power"] + s.pressure - s["magnetic-field"] - 0.5 * s.gravity - 0.05
  planet.surface_properties = planet.surface_properties or {}
  planet.surface_properties["infection-sterility"] = math.max(-0.2, math.min(0.2, v))
end

local adversary = data.raw.technology["chemical-science-pack"]
adversary.effects = adversary.effects or {}
table.insert(adversary.effects, {
  type = "nothing",
  effect_description = {"modifier-description.infection-adversary"},
  icons = {{icon = "__base__/graphics/icons/poison-capsule.png", icon_size = 64, tint = {r = 0.5, g = 1, b = 0.3}}},
})

for _, lab in pairs(data.raw.lab) do
  table.insert(lab.inputs, "infection")
  table.insert(lab.inputs, "infection-stabilized-spores")
end