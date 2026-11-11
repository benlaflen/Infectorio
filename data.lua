local TINT = {r = 0.5, g = 1, b = 0.3}
local STABLE_TINT = {r = 0.4, g = 0.7, b = 1}
local SPORE_ICON = "__base__/graphics/icons/poison-capsule.png"

local technologies = {
  {
    type = "technology",
    name = "infection-zero-day",
    icons = {{icon = SPORE_ICON, icon_size = 64, tint = TINT}},
    prerequisites = {},
    research_trigger = {type = "craft-item", item = "infection", count = 1},
  },
  {
    type = "technology",
    name = "infection-spore-containment",
    icons = {{icon = SPORE_ICON, icon_size = 64, tint = STABLE_TINT}},
    prerequisites = {"infection-zero-day"},
    effects = {
      {type = "unlock-recipe", recipe = "infection-stabilization-agent"},
      {type = "unlock-recipe", recipe = "infection-containment-unit"},
      {type = "unlock-recipe", recipe = "infection-stabilized-spores"},
    },
    unit = {
      count = 10,
      ingredients = {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1},
        {"chemical-science-pack", 1},
        {"infection", 1},
      },
      time = 30,
    },
  },
  {
    type = "technology",
    name = "infection-sterilization",
    icons = {{icon = "__base__/graphics/icons/repair-pack.png", icon_size = 64, tint = STABLE_TINT}},
    prerequisites = {"infection-zero-day"},
    effects = {{type = "unlock-recipe", recipe = "infection-sterilization-pack"}},
    unit = {
      count = 10,
      ingredients = {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1},
        {"chemical-science-pack", 1},
        {"infection", 1},
      },
      time = 30,
    },
  },
}
for _, technology in pairs(technologies) do technology.enabled = false end

data:extend{
  {type = "damage-type", name = "infection"},
  {
    type = "tool",
    name = "infection",
    icons = {{icon = SPORE_ICON, icon_size = 64, tint = TINT}},
    subgroup = "science-pack",
    order = "z[infection]-a",
    stack_size = 50,
    durability = 1,
    durability_description_key = "description.science-pack-remaining-amount-key",
    durability_description_value = "description.science-pack-remaining-amount-value",
    spoil_ticks = 10 * 60 * 60,
  },
  {
    type = "tool",
    name = "infection-stabilized-spores",
    icons = {{icon = SPORE_ICON, icon_size = 64, tint = STABLE_TINT}},
    subgroup = "science-pack",
    order = "z[infection]-b",
    stack_size = 50,
    durability = 1,
    durability_description_key = "description.science-pack-remaining-amount-key",
    durability_description_value = "description.science-pack-remaining-amount-value",
  },
  {
    type = "item",
    name = "infection-containment-unit",
    icons = {{icon = "__base__/graphics/icons/battery.png", icon_size = 64, tint = STABLE_TINT}},
    subgroup = "intermediate-product",
    order = "z[infection]-a",
    stack_size = 50,
  },
  {
    type = "tool",
    name = "infection-sterilization-pack",
    icons = {{icon = "__base__/graphics/icons/repair-pack.png", icon_size = 64, tint = STABLE_TINT}},
    subgroup = "tool",
    order = "z[infection]",
    stack_size = 100,
    durability = 1,
  },
  {type = "custom-input", name = "infection-apply", key_sequence = "mouse-button-1", action = "lua"},
  {
    type = "recipe",
    name = "infection-sterilization-pack",
    enabled = false,
    energy_required = 2,
    ingredients = {
      {type = "item", name = "sulfur", amount = 1},
      {type = "item", name = "plastic-bar", amount = 1},
    },
    results = {{type = "item", name = "infection-sterilization-pack", amount = 1}},
  },
  {
    type = "fluid",
    name = "infection-stabilization-agent",
    icons = {{icon = "__base__/graphics/icons/fluid/sulfuric-acid.png", icon_size = 64, tint = STABLE_TINT}},
    subgroup = "fluid",
    order = "z[infection]",
    default_temperature = 25,
    base_color = {r = 0.3, g = 0.5, b = 0.8},
    flow_color = {r = 0.6, g = 0.8, b = 1},
  },
  {
    type = "recipe",
    name = "infection-stabilization-agent",
    category = "chemistry",
    enabled = false,
    energy_required = 5,
    ingredients = {
      {type = "fluid", name = "sulfuric-acid", amount = 20},
      {type = "fluid", name = "steam", amount = 20},
    },
    results = {{type = "fluid", name = "infection-stabilization-agent", amount = 30}},
  },
  {
    type = "recipe",
    name = "infection-containment-unit",
    enabled = false,
    energy_required = 5,
    ingredients = {
      {type = "item", name = "plastic-bar", amount = 5},
      {type = "item", name = "iron-plate", amount = 6},
    },
    results = {{type = "item", name = "infection-containment-unit", amount = 1}},
  },
  {
    type = "recipe",
    name = "infection-stabilized-spores",
    category = "crafting-with-fluid",
    enabled = false,
    energy_required = 10,
    ingredients = {
      {type = "fluid", name = "infection-stabilization-agent", amount = 50},
      {type = "item", name = "infection-containment-unit", amount = 1},
      {type = "item", name = "infection", amount = 1},
    },
    results = {{type = "item", name = "infection-stabilized-spores", amount = 1}},
  },
}
data:extend(technologies)